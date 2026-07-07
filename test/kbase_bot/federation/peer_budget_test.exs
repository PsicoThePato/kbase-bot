defmodule KbaseBot.Federation.PeerBudgetTest do
  use ExUnit.Case, async: false

  alias KbaseBot.Federation.{Contacts, Disclosures, Grants, Inbox, PeerBudget}
  alias KbaseBot.Test.FederationFixtures

  setup do
    ctx = FederationFixtures.bootstrap()
    start_supervised!(KbaseBot.Repo.Store)
    start_supervised!(KbaseBot.Context.Server)
    start_supervised!({Task.Supervisor, name: KbaseBot.TaskSupervisor})
    start_supervised!(KbaseBot.Federation.Inbox)

    kb = Path.join(ctx.tmp, "kb")
    File.mkdir_p!(Path.join(kb, "movies"))

    File.write!(Path.join(kb, "movies/list.md"), """
    ---
    scopes: [movies]
    ---
    Dune Part Two: 9/10
    """)

    alice = FederationFixtures.peer("Alice")
    {:ok, _} = Contacts.add_card(alice.card)
    {:ok, _} = Grants.create(alice.id, "movies", ["query"])

    {:ok, Map.merge(ctx, %{alice: alice})}
  end

  test "check_and_increment trips at the configured cap and alerts once" do
    Application.put_env(:kbase_bot, :federation_peer_monthly_loops, 2)

    assert :ok = PeerBudget.check_and_increment("sha256:alice")
    assert :ok = PeerBudget.check_and_increment("sha256:alice")
    assert {:error, :budget_exhausted} = PeerBudget.check_and_increment("sha256:alice")

    assert_receive {:telegram, 4_242, text}, 500
    assert text =~ "inference budget"

    assert {:error, :budget_exhausted} = PeerBudget.check_and_increment("sha256:alice")
    refute_receive {:telegram, _, _}, 100

    # Another principal is unaffected.
    assert :ok = PeerBudget.check_and_increment("sha256:bob")
  end

  test "an exhausted peer's QUERY is declined as rate_limited, under budget it flows", ctx do
    Application.put_env(:kbase_bot, :federation_peer_monthly_loops, 1)

    query =
      FederationFixtures.envelope(ctx.alice, "QUERY", %{
        "scope" => "movies",
        "question" => "any good movies?"
      })

    Inbox.process(query)
    assert_receive {:federation_envelope, %{"kind" => "ANSWER"} = answer}, 3_000
    assert answer["answer"] =~ "FAKE-ANSWER"

    # The answer was recorded in the disclosure ledger (the envelope goes out
    # before the ledger row lands — poll instead of racing the task).
    assert await(fn ->
             match?([%{kind: "answer", scope: "movies"}], Disclosures.recent(ctx.alice.id))
           end)

    # Budget spent — the next QUERY gets a rate_limited DECLINE, no LLM loop.
    query2 =
      FederationFixtures.envelope(ctx.alice, "QUERY", %{
        "scope" => "movies",
        "question" => "more?"
      })

    Inbox.process(query2)
    assert_receive {:federation_envelope, %{"kind" => "DECLINE"} = decline}, 3_000
    assert decline["reason"] == "rate_limited"
    assert decline["in_reply_to"] == query2["id"]
  end

  defp await(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && await(fun, tries - 1)
    end
  end
end
