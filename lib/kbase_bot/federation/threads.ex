defmodule KbaseBot.Federation.Threads do
  @moduledoc """
  Discussion thread bookkeeping. A thread is pinned at open to
  (principal, scope); its messages live in the linked task, so each inbound
  SAY resumes the same bounded context. `role` records who opened it:
  "peer" or "owner". Turn budget counts inbound peer turns.
  """

  @spec insert(String.t(), String.t(), String.t(), String.t(), String.t(), integer()) :: :ok
  def insert(id, role, principal_id, scope, task_id, max_turns) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    KbaseBot.Repo.Store.execute(
      """
      INSERT OR REPLACE INTO threads (id, role, principal_id, scope, task_id, turn_count, max_turns, state, opened_at)
      VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, 'open', ?7)
      """,
      [id, role, principal_id, scope, task_id, max_turns, now]
    )

    :ok
  end

  @spec find(String.t()) :: {:ok, map()} | {:error, :not_found}
  def find(id) do
    case KbaseBot.Repo.Store.query(
           """
           SELECT id, role, principal_id, scope, task_id, turn_count, max_turns, state, opened_at, closed_at
           FROM threads WHERE id = ?1
           """,
           [id]
         ) do
      {:ok, [row | _]} -> {:ok, from_row(row)}
      _ -> {:error, :not_found}
    end
  end

  @spec increment_turns(String.t()) :: :ok
  def increment_turns(id) do
    KbaseBot.Repo.Store.execute(
      "UPDATE threads SET turn_count = turn_count + 1 WHERE id = ?1",
      [id]
    )

    :ok
  end

  @doc """
  Atomically claim one turn: increments the counter only while the thread is
  open and under budget, in a single statement — two concurrent SAYs can
  never both pass a stale check-then-increment. `:exhausted` means open but
  out of budget (caller should close); `:unavailable` means closed/missing.
  """
  @spec claim_turn(String.t()) :: :ok | :exhausted | :unavailable
  def claim_turn(id) do
    case KbaseBot.Repo.Store.query(
           """
           UPDATE threads SET turn_count = turn_count + 1
           WHERE id = ?1 AND state = 'open' AND turn_count < max_turns
           RETURNING turn_count
           """,
           [id]
         ) do
      {:ok, [[_count]]} ->
        :ok

      {:ok, []} ->
        case find(id) do
          {:ok, %{state: "open"}} -> :exhausted
          _ -> :unavailable
        end

      _ ->
        :unavailable
    end
  end

  @spec close(String.t()) :: :ok
  def close(id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    KbaseBot.Repo.Store.execute(
      "UPDATE threads SET state = 'closed', closed_at = ?1 WHERE id = ?2",
      [now, id]
    )

    :ok
  end

  defp from_row([
         id,
         role,
         principal_id,
         scope,
         task_id,
         turn_count,
         max_turns,
         state,
         opened_at,
         closed_at
       ]) do
    %{
      id: id,
      role: role,
      principal_id: principal_id,
      scope: scope,
      task_id: task_id,
      turn_count: turn_count,
      max_turns: max_turns,
      state: state,
      opened_at: opened_at,
      closed_at: closed_at
    }
  end
end
