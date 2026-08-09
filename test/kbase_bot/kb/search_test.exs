defmodule KbaseBot.KB.SearchTest do
  use ExUnit.Case, async: false

  alias KbaseBot.KB.{Chunker, Search}
  alias KbaseBot.Repo.Store
  alias KbaseBot.Test.FederationFixtures

  setup do
    ctx = FederationFixtures.bootstrap()
    start_supervised!(Store)
    start_supervised!(KbaseBot.Context.Server)

    root = KbaseBot.Context.Server.repo_path()
    File.mkdir_p!(Path.join(root, "nutrition"))

    File.write!(Path.join(root, "nutrition/supplements.md"), """
    # Supplements

    ## Creatine

    5g creatine monohydrate daily, taken with breakfast.

    ## Whey

    Whey protein after training sessions only.
    """)

    File.write!(Path.join(root, "notes.md"), """
    # Random notes

    The capybara is the largest living rodent.
    """)

    Chunker.reindex_all()
    {:ok, ctx}
  end

  test "FTS5 is available in this build" do
    assert Chunker.fts_available?()
  end

  test "keyword search finds the right chunk without any embedder" do
    {:ok, hits} = Search.search("creatine dose")

    assert [%{file: "nutrition/supplements.md", excerpt: excerpt} | _] = hits
    assert excerpt =~ "5g creatine"
  end

  test "hostile query characters do not crash the FTS parser" do
    for query <- ["a AND OR NOT (\"", "*, ^, :", "近い \"quoted\" -x", ""] do
      assert {:ok, hits} = Search.search(query)
      assert is_list(hits)
    end
  end

  test "reindex removes chunks for deleted files" do
    root = KbaseBot.Context.Server.repo_path()
    File.rm!(Path.join(root, "notes.md"))
    Chunker.reindex_all()

    {:ok, hits} = Search.search("capybara rodent")
    refute Enum.any?(hits, &(&1.file == "notes.md"))
    assert {:ok, [[0]]} = Store.query("SELECT COUNT(*) FROM kb_chunks WHERE path = 'notes.md'")
  end

  test "editing a file replaces its chunks" do
    root = KbaseBot.Context.Server.repo_path()
    File.write!(Path.join(root, "notes.md"), "# Random notes\n\nNow about axolotls instead.\n")
    Chunker.reindex_all()

    {:ok, hits} = Search.search("axolotls")
    assert Enum.any?(hits, &(&1.file == "notes.md"))

    {:ok, hits2} = Search.search("capybara")
    refute Enum.any?(hits2, &(&1.excerpt =~ "capybara"))
  end

  test "search_knowledge tool returns grant-filtered JSON for the owner" do
    {:ok, json} =
      KbaseBot.Tools.SearchKnowledge.execute(
        %{"query" => "whey protein"},
        %{principal: KbaseBot.Principal.owner()}
      )

    assert {:ok, [%{"file" => "nutrition/supplements.md"} | _]} = Jason.decode(json)
  end

  test "search_knowledge drops everything for an ungranted peer" do
    peer = %KbaseBot.Principal{id: "sha256:deadbeef", provider: :ed25519}

    {:ok, json} =
      KbaseBot.Tools.SearchKnowledge.execute(%{"query" => "whey protein"}, %{principal: peer})

    assert Jason.decode!(json) == []
  end
end
