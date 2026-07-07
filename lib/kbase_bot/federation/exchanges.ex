defmodule KbaseBot.Federation.Exchanges do
  @moduledoc """
  Exchange bookkeeping — the initiator rule's memory. Every envelope
  correlates (by id) to an exchange, and the exchange's initiator determines
  what its handling may do. Direction "out" = owner-initiated, "in" =
  peer-initiated. States: open → answered | declined | escalated → closed.
  """

  @spec open(String.t(), String.t(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok
  def open(direction, id, kind, peer, scope, question) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # OR IGNORE, not OR REPLACE: an id reuse must never flip an answered
    # exchange back to open (the first envelope wins; ids are single-use).
    KbaseBot.Repo.Store.execute(
      """
      INSERT OR IGNORE INTO exchanges (id, direction, kind, peer, scope, question, state, opened_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'open', ?7)
      """,
      [id, direction, kind, peer, scope, question, now]
    )

    :ok
  end

  @spec find(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def find(direction, id) do
    case KbaseBot.Repo.Store.query(
           """
           SELECT id, direction, kind, peer, scope, question, state, opened_at, closed_at
           FROM exchanges WHERE id = ?1 AND direction = ?2
           """,
           [id, direction]
         ) do
      {:ok, [row | _]} -> {:ok, from_row(row)}
      _ -> {:error, :not_found}
    end
  end

  @spec set_state(String.t(), String.t(), String.t()) :: :ok
  def set_state(direction, id, state) do
    closed_at =
      if state in ["answered", "declined", "closed"] do
        DateTime.utc_now() |> DateTime.to_iso8601()
      end

    KbaseBot.Repo.Store.execute(
      "UPDATE exchanges SET state = ?1, closed_at = COALESCE(?2, closed_at) WHERE id = ?3 AND direction = ?4",
      [state, closed_at, id, direction]
    )

    :ok
  end

  defp from_row([id, direction, kind, peer, scope, question, state, opened_at, closed_at]) do
    %{
      id: id,
      direction: direction,
      kind: kind,
      peer: peer,
      scope: scope,
      question: question,
      state: state,
      opened_at: opened_at,
      closed_at: closed_at
    }
  end
end
