defmodule KbaseBot.KB.WriterTest do
  use ExUnit.Case, async: false

  alias KbaseBot.KB.Writer
  alias KbaseBot.Repo.Store
  alias KbaseBot.Test.FederationFixtures

  setup do
    ctx = FederationFixtures.bootstrap()
    start_supervised!(Store)
    start_supervised!(KbaseBot.Context.Server)
    {:ok, ctx}
  end

  defp kb_path(rel), do: Path.join(KbaseBot.Context.Server.repo_path(), rel)

  test "write creates the file and logs provenance" do
    assert {:ok, _} =
             Writer.write("notes/a.md", "hello", actor: "bot", source: "test", meta: %{k: "v"})

    assert File.read!(kb_path("notes/a.md")) == "hello"

    assert {:ok, [[path, op, content, actor, source]]} =
             Store.query("SELECT path, op, content, actor, source FROM kb_writes")

    assert {path, op, content, actor, source} == {"notes/a.md", "write", "hello", "bot", "test"}
  end

  test "materialize! rebuilds bot-written files on a bare disk" do
    {:ok, _} = Writer.write("notes/a.md", "base\n")
    {:ok, _} = Writer.append("notes/a.md", "more\n")
    {:ok, _} = Writer.write("inbox/t/b.md", "quarantined")
    {:ok, _} = Writer.write("notes/gone.md", "temp")
    {:ok, _} = Writer.delete("notes/gone.md")

    # fresh host: vault baseline restored, bot-written files missing
    File.rm_rf!(kb_path("notes"))
    File.rm_rf!(kb_path("inbox"))

    assert :ok = Writer.materialize!()
    assert File.read!(kb_path("notes/a.md")) == "base\nmore\n"
    assert File.read!(kb_path("inbox/t/b.md")) == "quarantined"
    refute File.exists?(kb_path("notes/gone.md"))
  end

  test "append to an owner-authored file snapshots the base for replay" do
    # owner wrote this locally; it arrived via the vault, not via Writer
    File.mkdir_p!(kb_path("nutrition"))
    File.write!(kb_path("nutrition/plan.md"), "owner base\n")

    {:ok, _} = Writer.append("nutrition/plan.md", "bot addition\n")
    assert File.read!(kb_path("nutrition/plan.md")) == "owner base\nbot addition\n"

    File.rm!(kb_path("nutrition/plan.md"))
    assert :ok = Writer.materialize!()
    assert File.read!(kb_path("nutrition/plan.md")) == "owner base\nbot addition\n"
  end

  test "materialization never touches owner-authored paths" do
    File.mkdir_p!(kb_path("physical_training"))
    File.write!(kb_path("physical_training/routine.md"), "owner only")
    {:ok, _} = Writer.write("notes/bot.md", "bot file")

    assert :ok = Writer.materialize!()
    assert File.read!(kb_path("physical_training/routine.md")) == "owner only"
  end

  test "rejects paths escaping the knowledge base" do
    assert {:error, _} = Writer.write("../outside.md", "nope")
    assert {:error, _} = Writer.delete("nested/../../outside.md")
    refute File.exists?(Path.join(KbaseBot.Context.Server.repo_path(), "../outside.md"))
  end

  test "journal entries flow through the log and replay with header intact" do
    {:ok, filename, _time} = KbaseBot.Journal.Writer.append_entry("first thought")
    {:ok, ^filename, _time} = KbaseBot.Journal.Writer.append_entry("second thought")

    rel = Path.join("Journal", filename)
    on_disk = File.read!(kb_path(rel))
    assert on_disk =~ "---\ndate:"
    assert on_disk =~ "first thought"
    assert on_disk =~ "second thought"

    File.rm_rf!(kb_path("Journal"))
    assert :ok = Writer.materialize!()
    assert File.read!(kb_path(rel)) == on_disk

    assert {:ok, [[actor, source]]} =
             Store.query(
               "SELECT DISTINCT actor, source FROM kb_writes WHERE path = ?1",
               [rel]
             )

    assert {actor, source} == {"jairo", "journal"}
  end
end
