defmodule KbaseBot.Federation.TrustSignalsTest do
  use ExUnit.Case, async: false

  alias KbaseBot.Federation.TrustSignals
  alias KbaseBot.Principal
  alias KbaseBot.Test.FederationFixtures

  setup do
    ctx = FederationFixtures.bootstrap()
    start_supervised!(KbaseBot.Repo.Store)
    start_supervised!(KbaseBot.Context.Server)

    kb = Path.join(ctx.tmp, "kb")
    File.mkdir_p!(Path.join(kb, "inbox/movies"))

    File.write!(Path.join(kb, "inbox/movies/2026-07-06-dune-abc.md"), """
    ---
    name: Dune tip
    source: {principal: "sha256:kelvin", received: 2026-07-06}
    scopes: [private]
    ---

    > Pushed by sha256:kelvin

    Watch Dune.
    """)

    {:ok, Map.merge(ctx, %{kb: kb, owner: %{principal: Principal.owner()}})}
  end

  test "review_inbox lists items with their source", ctx do
    {:ok, listing} = KbaseBot.Tools.ReviewInbox.execute(%{}, ctx.owner)

    assert listing =~ "inbox/movies/2026-07-06-dune-abc.md"
    assert listing =~ "sha256:kelvin"
  end

  test "promote moves the file out of quarantine and logs the signal", ctx do
    {:ok, message} =
      KbaseBot.Tools.PromoteInboxItem.execute(
        %{"path" => "inbox/movies/2026-07-06-dune-abc.md"},
        ctx.owner
      )

    assert message =~ "movies/2026-07-06-dune-abc.md"
    refute File.exists?(Path.join(ctx.kb, "inbox/movies/2026-07-06-dune-abc.md"))
    assert File.exists?(Path.join(ctx.kb, "movies/2026-07-06-dune-abc.md"))

    assert [%{principal_id: "sha256:kelvin", topic: "movies", promoted: 1, discarded: 0}] =
             TrustSignals.stats()
  end

  test "discard deletes the file and logs the signal", ctx do
    {:ok, _} =
      KbaseBot.Tools.DiscardInboxItem.execute(
        %{"path" => "inbox/movies/2026-07-06-dune-abc.md"},
        ctx.owner
      )

    refute File.exists?(Path.join(ctx.kb, "inbox/movies/2026-07-06-dune-abc.md"))

    assert [%{principal_id: "sha256:kelvin", topic: "movies", promoted: 0, discarded: 1}] =
             TrustSignals.stats()
  end

  test "promotion refuses to land back inside inbox/ or outside the KB", ctx do
    assert {:error, _} =
             KbaseBot.Tools.PromoteInboxItem.execute(
               %{
                 "path" => "inbox/movies/2026-07-06-dune-abc.md",
                 "dest_dir" => "inbox/other"
               },
               ctx.owner
             )

    assert {:error, _} =
             KbaseBot.Tools.PromoteInboxItem.execute(
               %{
                 "path" => "inbox/movies/2026-07-06-dune-abc.md",
                 "dest_dir" => "../outside"
               },
               ctx.owner
             )

    assert File.exists?(Path.join(ctx.kb, "inbox/movies/2026-07-06-dune-abc.md"))
    assert TrustSignals.stats() == []
  end

  test "paths outside inbox/ are rejected", ctx do
    File.write!(Path.join(ctx.kb, "precious.md"), "mine")

    assert {:error, _} =
             KbaseBot.Tools.DiscardInboxItem.execute(%{"path" => "precious.md"}, ctx.owner)

    assert {:error, _} =
             KbaseBot.Tools.DiscardInboxItem.execute(
               %{"path" => "inbox/../precious.md"},
               ctx.owner
             )

    assert File.exists?(Path.join(ctx.kb, "precious.md"))
  end
end
