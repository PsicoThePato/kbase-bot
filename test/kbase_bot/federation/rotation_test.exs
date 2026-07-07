defmodule KbaseBot.Federation.RotationTest do
  use ExUnit.Case, async: false

  alias KbaseBot.Federation.{Canonical, Card, Circles, Contacts, Grants, Inbox, Rotation}
  alias KbaseBot.Identity.Keys
  alias KbaseBot.Test.FederationFixtures

  setup do
    ctx = FederationFixtures.bootstrap()
    start_supervised!(KbaseBot.Repo.Store)
    start_supervised!(KbaseBot.Context.Server)
    start_supervised!({Task.Supervisor, name: KbaseBot.TaskSupervisor})
    start_supervised!(KbaseBot.Federation.Inbox)
    {:ok, ctx}
  end

  # Alice rotates: her NEW key signs a card carrying a rotation proof her
  # OLD key signed. Returns {new_peer, rotation_card}.
  defp rotate_peer(peer) do
    {new_pub, new_priv} = :crypto.generate_key(:eddsa, :ed25519)
    new_id = Keys.fingerprint(new_pub)
    rotation = Card.rotation_proof(peer.pub, peer.priv, new_pub)

    card =
      Canonical.sign(
        %{
          "v" => 1,
          "principal" => new_id,
          "pubkey" => Base.encode64(new_pub),
          "display_name" => "Alice",
          "seq" => 2,
          "identity_providers" => ["ed25519"],
          "endpoints" => [%{"transport" => "loopback", "address" => "local", "priority" => 1}],
          "scopes" => [],
          "rotation" => rotation
        },
        new_priv
      )

    {%{id: new_id, pub: new_pub, priv: new_priv, card: card}, card}
  end

  test "a rotation CARD-UPDATE migrates the contact, grants and circles" do
    alice = FederationFixtures.peer("Alice")
    {:ok, _} = Contacts.add_card(alice.card)
    {:ok, _} = Grants.create(alice.id, "movies", ["query"])
    :ok = Circles.add("friends", alice.id)

    {new_alice, card} = rotate_peer(alice)

    env = FederationFixtures.envelope(new_alice, "CARD-UPDATE", %{"card" => card})
    assert :ok = Inbox.process(env)

    # Old contact gone, new one present.
    assert {:error, :not_found} = Contacts.find(alice.id)
    assert {:ok, %{display_name: "Alice"}} = Contacts.find(new_alice.id)

    # Grants re-issued to the new id; the old id holds nothing live.
    assert Grants.covers?(new_alice.id, "movies", ["query"])
    refute Grants.covers?(alice.id, "movies", ["query"])

    # Circle membership followed.
    assert Circles.members("friends") == [new_alice.id]

    # Owner heard about it.
    assert_receive {:telegram, 4_242, text}, 500
    assert text =~ "rotation"
  end

  test "a rotation proof signed by the wrong key is dropped" do
    alice = FederationFixtures.peer("Alice")
    {:ok, _} = Contacts.add_card(alice.card)
    {:ok, _} = Grants.create(alice.id, "movies", ["query"])

    # Mallory forges: proof signed by HER key, claiming Alice's id as old.
    mallory = FederationFixtures.peer("Mallory")
    {new_pub, new_priv} = :crypto.generate_key(:eddsa, :ed25519)
    new_id = Keys.fingerprint(new_pub)

    forged_proof =
      Canonical.sign(
        %{
          "v" => 1,
          "old" => alice.id,
          "old_pubkey" => Base.encode64(mallory.pub),
          "new" => new_id,
          "new_pubkey" => Base.encode64(new_pub)
        },
        mallory.priv
      )

    card =
      Canonical.sign(
        %{
          "v" => 1,
          "principal" => new_id,
          "pubkey" => Base.encode64(new_pub),
          "display_name" => "Alice",
          "seq" => 2,
          "identity_providers" => ["ed25519"],
          "endpoints" => [],
          "scopes" => [],
          "rotation" => forged_proof
        },
        new_priv
      )

    env =
      %{
        "v" => 1,
        "kind" => "CARD-UPDATE",
        "id" => KbaseBot.Federation.Envelope.new_id(),
        "ts" => System.os_time(:second),
        "from" => new_id,
        "card" => card
      }
      |> Canonical.sign(new_priv)

    assert :drop = Inbox.process(env)

    # `old_pubkey` doesn't fingerprint to Alice's id → invalid before it even
    # reaches the stored-key comparison; nothing migrated.
    assert {:ok, _} = Contacts.find(alice.id)
    assert Grants.covers?(alice.id, "movies", ["query"])
    refute match?({:ok, _}, Contacts.find(new_id))
  end

  test "a proof whose old key fingerprints correctly but differs from the stored one is rejected" do
    alice = FederationFixtures.peer("Alice")
    {:ok, _} = Contacts.add_card(alice.card)

    # An internally-consistent proof from a DIFFERENT keypair claiming to be
    # a rotation of... itself. The card verifies; Contacts must refuse
    # because the old id isn't a contact (or, if id collided, key mismatch).
    stranger = FederationFixtures.peer("Stranger")
    {new_alice, card} = rotate_peer(stranger)

    env = FederationFixtures.envelope(new_alice, "CARD-UPDATE", %{"card" => card})
    assert :drop = Inbox.process(env)
    refute match?({:ok, _}, Contacts.find(new_alice.id))
  end

  test "rotate_own generates a new identity, re-signs grants, and broadcasts" do
    alice = FederationFixtures.peer("Alice")
    {:ok, _} = Contacts.add_card(alice.card)

    {:ok, old_id} = Keys.own_principal_id()
    {:ok, _} = Grants.create(alice.id, "movies", ["query"])

    assert {:ok, %{old_id: ^old_id, new_id: new_id, notified: 1}} = Rotation.rotate_own()
    assert new_id != old_id
    assert {:ok, ^new_id} = Keys.own_principal_id()

    # The broadcast CARD-UPDATE reached Alice (loopback → test pid).
    assert_receive {:federation_envelope, %{"kind" => "CARD-UPDATE", "card" => card}}, 500
    assert card["principal"] == new_id
    assert card["rotation"]["old"] == old_id
    assert {:ok, _} = Card.verify(card)

    # Live grant records now carry the new issuer.
    assert [%{"iss" => ^new_id}] = Grants.all_live()

    # The proof persisted — future cards carry it.
    assert Rotation.proof()["new"] == new_id
  end
end
