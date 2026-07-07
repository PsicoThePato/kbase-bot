defmodule KbaseBot.Federation.VerifierTest do
  use ExUnit.Case, async: true

  alias KbaseBot.Federation.{Record, Verifier}

  @alice "sha256:alice"
  @carol "sha256:carol"

  defp grant(aud, scope, caps, caveats \\ %{}) do
    Record.new("sha256:me", aud, scope, caps, caveats)
  end

  describe "check/6 — direct (v1)" do
    test "live grant with the capability authorizes" do
      grants = [grant(@alice, "movies", ["query"])]
      assert {:ok, _} = Verifier.check(grants, @alice, "movies", "query")
    end

    test "missing capability, wrong scope, wrong audience all decline identically" do
      grants = [grant(@alice, "movies", ["query"])]

      assert {:error, :declined} = Verifier.check(grants, @alice, "movies", "subscribe")
      assert {:error, :declined} = Verifier.check(grants, @alice, "books", "query")
      assert {:error, :declined} = Verifier.check(grants, @carol, "movies", "query")
      assert {:error, :declined} = Verifier.check([], @alice, "movies", "query")
    end

    test "anyone pseudo-principal matches any verified principal" do
      grants = [grant(Verifier.anyone(), "movies", ["query"])]
      assert {:ok, _} = Verifier.check(grants, @carol, "movies", "query")
    end

    test "expired grants do not authorize" do
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601()
      grants = [grant(@alice, "movies", ["query"], %{"exp" => past})]
      assert {:error, :declined} = Verifier.check(grants, @alice, "movies", "query")
    end

    test "non-empty proof is declined in v1 (transitive out of scope)" do
      grants = [grant(@alice, "movies", ["query"])]
      proof = [Record.new(@alice, @carol, "movies", ["query"])]
      assert {:error, :declined} = Verifier.check(grants, @carol, "movies", "query", proof)
    end
  end

  describe "chain_depth_ok?/2 — the doc's worked example" do
    test "me(2) -> alice(1) -> carol(0) -> dave verifies at L=3" do
      chain = [
        Record.new("me", "alice", "movies", %{"query" => %{"depth" => 2}}),
        Record.new("alice", "carol", "movies", %{"query" => %{"depth" => 1}}),
        Record.new("carol", "dave", "movies", %{"query" => %{"depth" => 0}})
      ]

      assert Verifier.chain_depth_ok?(chain, "query")
    end

    test "depth 0 root cannot support any chain" do
      chain = [
        Record.new("me", "alice", "movies", %{"query" => %{"depth" => 0}}),
        Record.new("alice", "carol", "movies", %{"query" => %{"depth" => 0}})
      ]

      refute Verifier.chain_depth_ok?(chain, "query")
    end

    test "non-decreasing depth is rejected even when edge arithmetic passes" do
      chain = [
        Record.new("me", "alice", "movies", %{"query" => %{"depth" => 5}}),
        Record.new("alice", "carol", "movies", %{"query" => %{"depth" => 5}})
      ]

      refute Verifier.chain_depth_ok?(chain, "query")
    end

    test "single-edge chain needs only depth >= 0" do
      assert Verifier.chain_depth_ok?([Record.new("me", "alice", "movies", ["query"])], "query")
    end

    test "empty chain is invalid" do
      refute Verifier.chain_depth_ok?([], "query")
    end
  end
end
