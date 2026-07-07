defmodule KbaseBot.Federation.GrantPreviewTest do
  use ExUnit.Case, async: false

  alias KbaseBot.Federation.{GrantPreview, Grants}
  alias KbaseBot.Test.FederationFixtures

  setup do
    ctx = FederationFixtures.bootstrap()
    start_supervised!(KbaseBot.Repo.Store)
    start_supervised!(KbaseBot.Context.Server)

    kb = Path.join(ctx.tmp, "kb")
    File.mkdir_p!(Path.join(kb, "movies"))
    File.mkdir_p!(Path.join(kb, "inbox/movies"))

    File.write!(Path.join(kb, "movies/list.md"), """
    ---
    scopes: [movies]
    ---
    Dune Part Two: 9/10
    """)

    File.write!(Path.join(kb, "movies/with-friends.md"), """
    ---
    scopes: [movies, social]
    ---
    Watched with João
    """)

    File.write!(Path.join(kb, "secret.md"), "# Unlabeled — defaults to private\n")

    File.write!(Path.join(kb, "inbox/movies/pushed.md"), """
    ---
    scopes: [private]
    ---
    quarantined
    """)

    {:ok, ctx}
  end

  test "preview separates newly exposed, blocked co-scoped, and private files" do
    {:ok, result} = GrantPreview.preview("sha256:alice", "movies")

    assert result.newly_exposed == ["movies/list.md"]
    assert result.still_blocked == [{"movies/with-friends.md", ["social"]}]
    assert result.already_readable == 0
    # secret.md and the inbox item are private — in total, never in any bucket
    assert result.total == 4
  end

  test "an existing grant moves co-scoped files from blocked to newly exposed" do
    {:ok, _} = Grants.create("sha256:alice", "social", ["query"])

    {:ok, result} = GrantPreview.preview("sha256:alice", "movies")

    assert Enum.sort(result.newly_exposed) == ["movies/list.md", "movies/with-friends.md"]
    assert result.still_blocked == []
  end

  test "already-granted files count as readable, not newly exposed" do
    {:ok, _} = Grants.create("sha256:alice", "movies", ["query"])

    {:ok, result} = GrantPreview.preview("sha256:alice", "movies")

    assert result.newly_exposed == []
    assert result.already_readable == 1
  end

  test "non-grantable scopes are refused" do
    assert {:error, message} = GrantPreview.preview("sha256:alice", "private")
    assert message =~ "non-grantable"
  end
end
