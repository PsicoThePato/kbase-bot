defmodule KbaseBot.Federation.TrustSignals do
  @moduledoc """
  The labeled training data the future trust algorithm needs, captured now.
  Every owner verdict on a quarantined inbox item — promote (worth keeping)
  or discard — is logged per (principal, topic). The design doc's feedback
  loop ("Kelvin's computation gossip: 80% promoted; his movie gossip: mostly
  discarded") starts as exactly these rows; capturing them costs nothing and
  means the recommendation policy starts warm instead of cold.

  This module only records and aggregates. It makes no decisions.
  """

  alias KbaseBot.Repo.Store

  @actions ~w(promote discard)

  @doc "Record one owner verdict on an inbox item."
  @spec log(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def log(principal_id, topic, item, action) when action in @actions do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Store.execute(
      """
      INSERT INTO trust_signals (principal_id, topic, item, action, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5)
      """,
      [principal_id, topic, item, action, now]
    )

    :ok
  end

  def log(_, _, _, action), do: {:error, "unknown action #{inspect(action)}"}

  @doc "Promote/discard counts per (principal, topic), optionally for one principal."
  @spec stats(String.t() | nil) :: [map()]
  def stats(principal_id \\ nil) do
    {sql, params} =
      if principal_id do
        {"SELECT principal_id, topic, action, COUNT(*) FROM trust_signals " <>
           "WHERE principal_id = ?1 GROUP BY principal_id, topic, action " <>
           "ORDER BY principal_id, topic", [principal_id]}
      else
        {"SELECT principal_id, topic, action, COUNT(*) FROM trust_signals " <>
           "GROUP BY principal_id, topic, action ORDER BY principal_id, topic", []}
      end

    case Store.query(sql, params) do
      {:ok, rows} ->
        rows
        |> Enum.group_by(
          fn [principal, topic, _action, _count] -> {principal, topic} end,
          fn [_p, _t, action, count] -> {action, count} end
        )
        |> Enum.map(fn {{principal, topic}, actions} ->
          counts = Map.new(actions)

          %{
            principal_id: principal,
            topic: topic,
            promoted: Map.get(counts, "promote", 0),
            discarded: Map.get(counts, "discard", 0)
          }
        end)
        |> Enum.sort_by(&{&1.principal_id, &1.topic})

      _ ->
        []
    end
  end

  @doc "Re-key history to a rotated principal id — trust continuity across rotation."
  @spec rekey(String.t(), String.t()) :: :ok
  def rekey(old_id, new_id) do
    Store.execute("UPDATE trust_signals SET principal_id = ?1 WHERE principal_id = ?2", [
      new_id,
      old_id
    ])

    :ok
  end
end
