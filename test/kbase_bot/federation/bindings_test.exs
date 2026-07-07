defmodule KbaseBot.Federation.BindingsTest do
  use ExUnit.Case, async: false

  alias KbaseBot.Federation.Bindings

  setup do
    tmp = Path.join(System.tmp_dir!(), "kbase_bind_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    old = Application.get_env(:kbase_bot, :db_path)
    Application.put_env(:kbase_bot, :db_path, Path.join(tmp, "test.db"))
    start_supervised!(KbaseBot.Repo.Store)

    on_exit(fn ->
      if old,
        do: Application.put_env(:kbase_bot, :db_path, old),
        else: Application.delete_env(:kbase_bot, :db_path)

      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "resolve orders confirmed above higher-confidence auto" do
    Bindings.upsert("health", "sha256:alice", "fitness", 95, false)
    Bindings.upsert("health", "sha256:alice", "saude", 60, true)

    assert ["saude", "fitness"] = Bindings.resolve("health", "sha256:alice")
  end

  test "resolve is scoped per peer and topic" do
    Bindings.upsert("health", "sha256:alice", "saude", 90, false)

    assert [] = Bindings.resolve("health", "sha256:bob")
    assert [] = Bindings.resolve("movies", "sha256:alice")
  end

  test "upsert never downgrades confirmation or confidence" do
    Bindings.upsert("health", "sha256:alice", "saude", 90, true)
    Bindings.upsert("health", "sha256:alice", "saude", 50, false)

    assert [%{confirmed: true, confidence: 90}] = Bindings.list()
  end

  test "delete removes one binding or all for a topic+peer" do
    Bindings.upsert("health", "sha256:alice", "saude", 90, false)
    Bindings.upsert("health", "sha256:alice", "fitness", 85, false)

    Bindings.delete("health", "sha256:alice", "saude")
    assert ["fitness"] = Bindings.resolve("health", "sha256:alice")

    Bindings.delete("health", "sha256:alice")
    assert [] = Bindings.resolve("health", "sha256:alice")
  end
end
