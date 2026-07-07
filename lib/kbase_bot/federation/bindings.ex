defmodule KbaseBot.Federation.Bindings do
  @moduledoc """
  The translation layer: owner-private rows mapping my topics to specific
  peers' scope labels. Topics never cross the wire; the mapping is consulted
  at query-composition and subscription time. Confirmed bindings outrank
  auto-proposed ones.
  """

  @spec upsert(String.t(), String.t(), String.t(), integer(), boolean()) :: :ok
  def upsert(topic, principal_id, peer_scope, confidence, confirmed) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    KbaseBot.Repo.Store.execute(
      """
      INSERT INTO bindings (topic, principal_id, peer_scope, confidence, confirmed, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      ON CONFLICT (topic, principal_id, peer_scope)
      DO UPDATE SET confidence = MAX(confidence, excluded.confidence),
                    confirmed = MAX(confirmed, excluded.confirmed)
      """,
      [topic, principal_id, peer_scope, confidence, if(confirmed, do: 1, else: 0), now]
    )

    :ok
  end

  @doc "Peer scopes bound to `topic` at `principal_id`, best first (confirmed > confidence)."
  @spec resolve(String.t(), String.t()) :: [String.t()]
  def resolve(topic, principal_id) do
    case KbaseBot.Repo.Store.query(
           """
           SELECT peer_scope FROM bindings
           WHERE topic = ?1 AND principal_id = ?2
           ORDER BY confirmed DESC, confidence DESC
           """,
           [topic, principal_id]
         ) do
      {:ok, rows} -> Enum.map(rows, fn [scope] -> scope end)
      _ -> []
    end
  end

  @spec delete(String.t(), String.t(), String.t() | nil) :: :ok
  def delete(topic, principal_id, peer_scope \\ nil) do
    if peer_scope do
      KbaseBot.Repo.Store.execute(
        "DELETE FROM bindings WHERE topic = ?1 AND principal_id = ?2 AND peer_scope = ?3",
        [topic, principal_id, peer_scope]
      )
    else
      KbaseBot.Repo.Store.execute(
        "DELETE FROM bindings WHERE topic = ?1 AND principal_id = ?2",
        [topic, principal_id]
      )
    end

    :ok
  end

  @spec list() :: [map()]
  def list do
    case KbaseBot.Repo.Store.query("""
         SELECT topic, principal_id, peer_scope, confidence, confirmed, created_at
         FROM bindings ORDER BY topic, principal_id
         """) do
      {:ok, rows} ->
        Enum.map(rows, fn [topic, principal_id, peer_scope, confidence, confirmed, created_at] ->
          %{
            topic: topic,
            principal_id: principal_id,
            peer_scope: peer_scope,
            confidence: confidence,
            confirmed: confirmed == 1,
            created_at: created_at
          }
        end)

      _ ->
        []
    end
  end
end
