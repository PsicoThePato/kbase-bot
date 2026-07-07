defmodule KbaseBot.Federation.PeerBudget do
  @moduledoc """
  Monthly ceiling on peer-triggered inference, per principal. Every
  peer-initiated envelope that spawns an LLM loop (QUERY → responder,
  PUBLISH → evaluator, SAY → discussant turn) counts one loop against the
  sender's month; past the cap the peer gets a DECLINE (`rate_limited`)
  instead of our tokens. Owner-initiated work (our own queries, the
  interlocutor processing answers WE asked for) is never budgeted.

  Loops, not tokens: each loop is already turn-capped, so a loop count is a
  hard bound on spend — and like `LLM.Budget`, a fuse only needs to blow,
  not to meter. Fail-open on store trouble for the same reason as there:
  the budget protects the wallet, it must not be what breaks federation
  (and a dead store already stops envelope processing at the replay check).
  """

  require Logger

  alias KbaseBot.Federation.OwnerNotifier
  alias KbaseBot.Repo.Store

  @default_monthly_loops 100

  @doc """
  Count one prospective peer-triggered loop for `principal_id` this month.
  `:ok` to proceed, `{:error, :budget_exhausted}` past the cap (owner alerted
  once per peer per month).
  """
  @spec check_and_increment(String.t()) :: :ok | {:error, :budget_exhausted}
  def check_and_increment(principal_id) do
    budget =
      Application.get_env(:kbase_bot, :federation_peer_monthly_loops) || @default_monthly_loops

    month = month_key()

    with :ok <-
           Store.execute(
             "INSERT INTO peer_llm_usage (month, principal_id, loops) VALUES (?1, ?2, 1) " <>
               "ON CONFLICT(month, principal_id) DO UPDATE SET loops = loops + 1",
             [month, principal_id]
           ),
         {:ok, [[loops, alerted]]} <-
           Store.query(
             "SELECT loops, alerted FROM peer_llm_usage WHERE month = ?1 AND principal_id = ?2",
             [month, principal_id]
           ) do
      if loops <= budget do
        :ok
      else
        if alerted == 0, do: alert(month, principal_id, budget)
        {:error, :budget_exhausted}
      end
    else
      other ->
        Logger.warning("Peer budget check unavailable (#{inspect(other)}) — allowing loop")
        :ok
    end
  rescue
    e ->
      Logger.warning("Peer budget check crashed (#{inspect(e)}) — allowing loop")
      :ok
  catch
    kind, reason ->
      Logger.warning("Peer budget check #{kind} (#{inspect(reason)}) — allowing loop")
      :ok
  end

  @doc "Loops used per principal this month, for the owner's report."
  @spec usage() :: [map()]
  def usage do
    case Store.query(
           "SELECT principal_id, loops FROM peer_llm_usage WHERE month = ?1 ORDER BY loops DESC",
           [month_key()]
         ) do
      {:ok, rows} ->
        Enum.map(rows, fn [principal_id, loops] -> %{peer: principal_id, loops: loops} end)

      _ ->
        []
    end
  end

  defp alert(month, principal_id, budget) do
    Store.execute(
      "UPDATE peer_llm_usage SET alerted = 1 WHERE month = ?1 AND principal_id = ?2",
      [month, principal_id]
    )

    OwnerNotifier.notify_owner(
      "[Federation] #{OwnerNotifier.safe_token(principal_id)} exhausted their monthly " <>
        "inference budget (#{budget} loops) — declining their traffic until next month. " <>
        "Raise FEDERATION_PEER_MONTHLY_BUDGET if this is a peer you want to serve more."
    )
  end

  defp month_key do
    %Date{year: y, month: m} = Date.utc_today()
    :io_lib.format("~4..0B-~2..0B", [y, m]) |> IO.iodata_to_binary()
  end
end
