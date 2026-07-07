defmodule KbaseBot.Federation.RecordTest do
  use ExUnit.Case, async: true

  alias KbaseBot.Federation.Record

  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  test "list caps sugar normalizes to depth 0" do
    r = Record.new("sha256:me", "sha256:alice", "movies", ["query", "read"])
    assert r["caps"] == %{"query" => %{"depth" => 0}, "read" => %{"depth" => 0}}
    assert Record.cap_depth(r, "query") == 0
    assert Record.has_cap?(r, "read")
    refute Record.has_cap?(r, "discuss")
  end

  test "map caps carry explicit depth" do
    r = Record.new("me", "alice", "movies", %{"query" => %{"depth" => 2}})
    assert Record.cap_depth(r, "query") == 2
  end

  test "sign/verify roundtrip; tampering breaks the signature" do
    {pub, priv} = keypair()
    r = Record.new("me", "alice", "movies", ["query"]) |> Record.sign(priv)

    assert Record.verified?(r, pub)
    refute Record.verified?(%{r | "scope" => "medical"}, pub)
  end

  describe "valid_now?/2" do
    test "no exp is valid" do
      assert Record.valid_now?(Record.new("m", "a", "s", ["query"]))
    end

    test "future exp valid, past exp invalid, garbage exp invalid" do
      future = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      past = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()

      assert Record.valid_now?(Record.new("m", "a", "s", ["query"], %{"exp" => future}))
      refute Record.valid_now?(Record.new("m", "a", "s", ["query"], %{"exp" => past}))
      refute Record.valid_now?(Record.new("m", "a", "s", ["query"], %{"exp" => "not-a-date"}))
    end
  end

  describe "attenuates?/2" do
    setup do
      parent = Record.new("me", "alice", "movies", %{"query" => %{"depth" => 2}})
      {:ok, parent: parent}
    end

    test "legal attenuation: subset caps, strictly smaller depth", %{parent: parent} do
      child = Record.new("alice", "carol", "movies", %{"query" => %{"depth" => 1}})
      assert Record.attenuates?(child, parent)
    end

    test "equal depth is NOT attenuation", %{parent: parent} do
      child = Record.new("alice", "carol", "movies", %{"query" => %{"depth" => 2}})
      refute Record.attenuates?(child, parent)
    end

    test "cap widening is rejected", %{parent: parent} do
      child = Record.new("alice", "carol", "movies", %{"read" => %{"depth" => 0}})
      refute Record.attenuates?(child, parent)
    end

    test "scope change is rejected", %{parent: parent} do
      child = Record.new("alice", "carol", "books", %{"query" => %{"depth" => 1}})
      refute Record.attenuates?(child, parent)
    end

    test "chain must connect: child.iss == parent.aud", %{parent: parent} do
      child = Record.new("mallory", "carol", "movies", %{"query" => %{"depth" => 1}})
      refute Record.attenuates?(child, parent)
    end

    test "expiry can never extend" do
      exp = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      later = DateTime.utc_now() |> DateTime.add(7200) |> DateTime.to_iso8601()

      parent =
        Record.new("me", "alice", "movies", %{"query" => %{"depth" => 2}}, %{"exp" => exp})

      no_exp_child = Record.new("alice", "carol", "movies", %{"query" => %{"depth" => 1}})
      refute Record.attenuates?(no_exp_child, parent)

      extended =
        Record.new("alice", "carol", "movies", %{"query" => %{"depth" => 1}}, %{"exp" => later})

      refute Record.attenuates?(extended, parent)

      shorter =
        Record.new("alice", "carol", "movies", %{"query" => %{"depth" => 1}}, %{"exp" => exp})

      assert Record.attenuates?(shorter, parent)
    end
  end
end
