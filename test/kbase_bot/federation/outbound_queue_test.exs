defmodule KbaseBot.Federation.OutboundQueueTest do
  use ExUnit.Case, async: false

  alias KbaseBot.Federation.{Contacts, Outbound, OutboundQueue}
  alias KbaseBot.Repo.Store
  alias KbaseBot.Test.FederationFixtures

  setup do
    ctx = FederationFixtures.bootstrap()
    start_supervised!(KbaseBot.Repo.Store)
    {:ok, ctx}
  end

  defp unreachable_peer(name) do
    # An endpoint whose transport we don't speak — every attempt fails.
    FederationFixtures.peer(name, [
      %{"transport" => "carrier-pigeon", "address" => "roof", "priority" => 1}
    ])
  end

  test "deliver falls back to the durable queue and deliver_due retries" do
    peer = unreachable_peer("Alice")
    {:ok, _} = Contacts.add_card(peer.card)

    assert :ok = Outbound.deliver(%{"kind" => "ANSWER", "id" => "e1"}, peer.id)

    assert [%{state: "queued", count: 1}] = OutboundQueue.status()
    # Nothing arrived at the loopback receiver.
    refute_receive {:federation_envelope, _}, 50

    # The peer comes back online: replace the card with a loopback endpoint.
    {:ok, _} =
      Contacts.add_card(
        KbaseBot.Federation.Canonical.sign(
          peer.card
          |> Map.delete("sig")
          |> Map.put("seq", 2)
          |> Map.put("endpoints", [
            %{"transport" => "loopback", "address" => "local", "priority" => 1}
          ]),
          peer.priv
        )
      )

    # Force the row due now.
    Store.execute("UPDATE outbound_queue SET next_attempt_at = '2000-01-01T00:00:00Z'", [])
    OutboundQueue.deliver_due()

    assert_receive {:federation_envelope, %{"id" => "e1"}}, 500
    assert OutboundQueue.status() == []
  end

  test "unknown contact is a hard error, not a queue entry" do
    assert {:error, :unknown_contact} = Outbound.deliver(%{"kind" => "ANSWER"}, "sha256:nobody")
    assert OutboundQueue.status() == []
  end

  test "envelopes older than the freshness window are dead-lettered" do
    peer = unreachable_peer("Alice")
    {:ok, _} = Contacts.add_card(peer.card)

    :ok = Outbound.deliver(%{"kind" => "ANSWER", "id" => "old"}, peer.id)

    Store.execute(
      "UPDATE outbound_queue SET next_attempt_at = '2000-01-01T00:00:00Z', created_at = '2000-01-01T00:00:00Z'",
      []
    )

    OutboundQueue.deliver_due()

    assert [%{state: "dead"}] = OutboundQueue.status()
  end

  test "owner is alerted once when a peer is unreachable past the threshold" do
    Application.put_env(:kbase_bot, :federation_unreachable_alert_s, 60)

    peer = unreachable_peer("Alice")
    {:ok, _} = Contacts.add_card(peer.card)

    :ok = Outbound.deliver(%{"kind" => "ANSWER", "id" => "e1"}, peer.id)

    old = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    Store.execute(
      "UPDATE outbound_queue SET next_attempt_at = '2000-01-01T00:00:00Z', created_at = ?1",
      [old]
    )

    OutboundQueue.deliver_due()
    assert_receive {:telegram, 4_242, text}, 500
    assert text =~ "unreachable"

    # A second failing pass does not re-alert.
    Store.execute("UPDATE outbound_queue SET next_attempt_at = '2000-01-01T00:00:00Z'", [])
    OutboundQueue.deliver_due()
    refute_receive {:telegram, _, _}, 100
  end
end
