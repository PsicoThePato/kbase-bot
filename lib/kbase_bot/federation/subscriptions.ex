defmodule KbaseBot.Federation.Subscriptions do
  @moduledoc """
  Standing feeds. Direction "in" = a peer subscribed to one of my scopes
  (publisher side; re-verified against live grants before every PUBLISH).
  Direction "out" = I subscribed to a peer's scope (standing owner intent —
  the initiator rule's memory for inbound PUBLISH). `topic` on out-rows is
  my own label, used to file items in the quarantine inbox.
  """

  @spec upsert(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def upsert(direction, principal_id, scope, topic) do
    id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    KbaseBot.Repo.Store.execute(
      """
      INSERT INTO subscriptions (id, direction, principal_id, scope, topic, state, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, 'active', ?6)
      ON CONFLICT (direction, principal_id, scope)
      DO UPDATE SET state = 'active', topic = COALESCE(excluded.topic, topic)
      """,
      [id, direction, principal_id, scope, topic, now]
    )

    :ok
  end

  @spec find_active(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def find_active(direction, principal_id, scope) do
    case KbaseBot.Repo.Store.query(
           """
           SELECT id, direction, principal_id, scope, topic, state, created_at
           FROM subscriptions
           WHERE direction = ?1 AND principal_id = ?2 AND scope = ?3 AND state = 'active'
           """,
           [direction, principal_id, scope]
         ) do
      {:ok, [row | _]} -> {:ok, from_row(row)}
      _ -> {:error, :not_found}
    end
  end

  @doc "Active publisher-side subscriptions on a scope."
  @spec active_subscribers(String.t()) :: [map()]
  def active_subscribers(scope) do
    case KbaseBot.Repo.Store.query(
           """
           SELECT id, direction, principal_id, scope, topic, state, created_at
           FROM subscriptions
           WHERE direction = 'in' AND scope = ?1 AND state = 'active'
           """,
           [scope]
         ) do
      {:ok, rows} -> Enum.map(rows, &from_row/1)
      _ -> []
    end
  end

  @spec set_state(String.t(), String.t(), String.t(), String.t()) :: :ok
  def set_state(direction, principal_id, scope, state) do
    KbaseBot.Repo.Store.execute(
      """
      UPDATE subscriptions SET state = ?1
      WHERE direction = ?2 AND principal_id = ?3 AND scope = ?4
      """,
      [state, direction, principal_id, scope]
    )

    :ok
  end

  @spec list() :: [map()]
  def list do
    case KbaseBot.Repo.Store.query("""
         SELECT id, direction, principal_id, scope, topic, state, created_at
         FROM subscriptions ORDER BY created_at
         """) do
      {:ok, rows} -> Enum.map(rows, &from_row/1)
      _ -> []
    end
  end

  defp from_row([id, direction, principal_id, scope, topic, state, created_at]) do
    %{
      id: id,
      direction: direction,
      principal_id: principal_id,
      scope: scope,
      topic: topic,
      state: state,
      created_at: created_at
    }
  end
end
