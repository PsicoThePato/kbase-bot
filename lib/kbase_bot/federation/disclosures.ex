defmodule KbaseBot.Federation.Disclosures do
  @moduledoc """
  The disclosure ledger: every piece of substantive content this bot sends a
  peer — answers, discussion turns, published items, and the questions we
  compose for external ears — is logged per (peer, scope). Grants say what a
  peer MAY see; this ledger says what they actually got, so the owner can
  audit ("what has my bot told Bob this month?") instead of trusting deny-by-
  default blindly.

  Logging is best-effort and must never block delivery: the ledger is an
  audit aid, not an authorization gate (the Verifier and Policy are).
  """

  require Logger

  @summary_limit 500

  @doc "Record one outbound disclosure. `kind` ∈ answer|say|publish|query|discuss-open."
  @spec log(String.t(), String.t() | nil, String.t(), String.t() | nil, String.t()) :: :ok
  def log(peer, scope, kind, ref_id, content) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    KbaseBot.Repo.Store.execute(
      """
      INSERT INTO disclosures (peer, scope, kind, ref_id, summary, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [peer, scope, kind, ref_id, String.slice(content || "", 0, @summary_limit), now]
    )

    :ok
  rescue
    e ->
      Logger.warning("Disclosure ledger write failed: #{inspect(e)}")
      :ok
  catch
    kind_, reason ->
      Logger.warning("Disclosure ledger write #{kind_}: #{inspect(reason)}")
      :ok
  end

  @doc "Recent disclosures, newest first, optionally filtered to one peer."
  @spec recent(String.t() | nil, non_neg_integer(), non_neg_integer()) :: [map()]
  def recent(peer \\ nil, days \\ 30, limit \\ 50) do
    since =
      DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.to_iso8601()

    {sql, params} =
      if peer do
        {"SELECT peer, scope, kind, ref_id, summary, created_at FROM disclosures " <>
           "WHERE created_at >= ?1 AND peer = ?2 ORDER BY created_at DESC LIMIT ?3",
         [since, peer, limit]}
      else
        {"SELECT peer, scope, kind, ref_id, summary, created_at FROM disclosures " <>
           "WHERE created_at >= ?1 ORDER BY created_at DESC LIMIT ?2", [since, limit]}
      end

    case KbaseBot.Repo.Store.query(sql, params) do
      {:ok, rows} ->
        Enum.map(rows, fn [peer_, scope, kind, ref_id, summary, created_at] ->
          %{
            peer: peer_,
            scope: scope,
            kind: kind,
            ref_id: ref_id,
            summary: summary,
            created_at: created_at
          }
        end)

      _ ->
        []
    end
  end

  @doc "Counts per (peer, scope, kind) within the window — the audit rollup."
  @spec summary(String.t() | nil, non_neg_integer()) :: [map()]
  def summary(peer \\ nil, days \\ 30) do
    since =
      DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.to_iso8601()

    {sql, params} =
      if peer do
        {"SELECT peer, scope, kind, COUNT(*) FROM disclosures " <>
           "WHERE created_at >= ?1 AND peer = ?2 GROUP BY peer, scope, kind " <>
           "ORDER BY peer, scope, kind", [since, peer]}
      else
        {"SELECT peer, scope, kind, COUNT(*) FROM disclosures " <>
           "WHERE created_at >= ?1 GROUP BY peer, scope, kind ORDER BY peer, scope, kind",
         [since]}
      end

    case KbaseBot.Repo.Store.query(sql, params) do
      {:ok, rows} ->
        Enum.map(rows, fn [peer_, scope, kind, count] ->
          %{peer: peer_, scope: scope, kind: kind, count: count}
        end)

      _ ->
        []
    end
  end

  @doc "Re-key history to a rotated principal id — trust continuity across rotation."
  @spec rekey(String.t(), String.t()) :: :ok
  def rekey(old_id, new_id) do
    KbaseBot.Repo.Store.execute("UPDATE disclosures SET peer = ?1 WHERE peer = ?2", [
      new_id,
      old_id
    ])

    :ok
  end
end
