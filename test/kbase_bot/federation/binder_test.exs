defmodule KbaseBot.Federation.BinderTest do
  use ExUnit.Case, async: true

  alias KbaseBot.Federation.Binder

  describe "classify/3" do
    @topics ["health", "movies"]
    @peer_scopes ["saude", "filmes", "crypto"]

    test "splits by thresholds: >=80 auto, 50-79 ask, <50 dropped" do
      proposals = [
        %{"topic" => "health", "peer_scope" => "saude", "confidence" => 95},
        %{"topic" => "movies", "peer_scope" => "filmes", "confidence" => 70},
        %{"topic" => "movies", "peer_scope" => "crypto", "confidence" => 20}
      ]

      {auto, ask} = Binder.classify(proposals, @topics, @peer_scopes)

      assert [%{"peer_scope" => "saude"}] = auto
      assert [%{"peer_scope" => "filmes"}] = ask
    end

    test "hallucinated topics or scopes are rejected regardless of confidence" do
      proposals = [
        %{"topic" => "invented", "peer_scope" => "saude", "confidence" => 99},
        %{"topic" => "health", "peer_scope" => "not-theirs", "confidence" => 99},
        %{"topic" => "health", "peer_scope" => "saude", "confidence" => "high"}
      ]

      assert {[], []} = Binder.classify(proposals, @topics, @peer_scopes)
    end

    test "garbage proposals do not crash" do
      assert {[], []} = Binder.classify([nil, "x", %{}], @topics, @peer_scopes)
    end
  end

  describe "owner_topics/1" do
    test "collects scopes from defaults and descriptions, excluding private" do
      policy = %{
        "defaults" => %{
          "Journal/**" => %{"scopes" => ["journal"]},
          "**" => %{"scopes" => ["private"]}
        },
        "scope_descriptions" => %{"movies" => "films & ratings"}
      }

      assert Binder.owner_topics(policy) == ["journal", "movies"]
    end
  end
end
