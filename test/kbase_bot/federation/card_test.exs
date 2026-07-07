defmodule KbaseBot.Federation.CardTest do
  use ExUnit.Case, async: true

  alias KbaseBot.Federation.{Canonical, Card}
  alias KbaseBot.Identity.Keys

  defp signed_card do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    card = %{
      "v" => 1,
      "principal" => Keys.fingerprint(pub),
      "pubkey" => Base.encode64(pub),
      "display_name" => "Alice",
      "seq" => 1,
      "identity_providers" => ["ed25519"],
      "endpoints" => [%{"transport" => "https", "address" => "https://kb.alice.dev/inbox"}],
      "scopes" => []
    }

    {Canonical.sign(card, priv), pub}
  end

  test "a self-signed card verifies" do
    {card, _pub} = signed_card()
    assert {:ok, ^card} = Card.verify(card)
  end

  test "fingerprint/pubkey mismatch is rejected" do
    {card, _} = signed_card()
    forged = Map.put(card, "principal", "sha256:" <> String.duplicate("ab", 32))
    assert {:error, :invalid_card} = Card.verify(forged)
  end

  test "tampered content is rejected" do
    {card, _} = signed_card()
    assert {:error, :invalid_card} = Card.verify(Map.put(card, "seq", 99))
  end

  test "cards without a pubkey are rejected" do
    {card, _} = signed_card()
    assert {:error, :invalid_card} = Card.verify(Map.delete(card, "pubkey"))
  end

  test "pubkey/1 extracts the raw key" do
    {card, pub} = signed_card()
    assert {:ok, ^pub} = Card.pubkey(card)
  end
end
