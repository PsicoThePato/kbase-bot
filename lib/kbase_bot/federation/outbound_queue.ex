defmodule KbaseBot.Federation.OutboundQueue do
  @moduledoc """
  Store-and-forward for envelopes whose first delivery attempt failed. The
  protocol is async — a peer's hobby VPS being down for an hour must not
  lose an ANSWER — so failed envelopes land in a durable SQLite queue and
  are retried with exponential backoff.

  Retention mirrors the receiver's replay window: an envelope's signed `ts`
  goes stale after 7 days, so retrying past that is pointless — the row is
  dead-lettered instead. Per-peer delivery is in submission order, and a
  failure parks the whole peer until the next tick (a later envelope must
  not overtake a stuck earlier one within a tick).

  When a peer's oldest queued envelope crosses the unreachable threshold the
  owner is told once; the alert re-arms after the next successful delivery.

  `enqueue/2` is a plain DB write — no GenServer needed — so any caller
  (including tests without the queue process) can park an envelope. The
  GenServer only owns the retry tick.
  """

  use GenServer

  alias KbaseBot.Federation.{Contacts, OwnerNotifier, Transport}
  alias KbaseBot.Repo.Store

  require Logger

  @default_tick_ms 60_000
  # Mirrors the Inbox freshness window (@max_age_s): receivers drop older envelopes.
  @max_age_s 7 * 86_400
  @backoff_base_s 60
  @backoff_cap_s 6 * 3_600
  @default_unreachable_alert_s 3 * 86_400
  @batch 50

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Park an envelope for retry after a failed delivery attempt."
  @spec enqueue(map(), String.t(), term()) :: :ok
  def enqueue(envelope, peer_id, last_error \\ nil) do
    now = DateTime.utc_now()

    Store.execute(
      """
      INSERT INTO outbound_queue (peer, envelope_json, state, attempts, next_attempt_at, last_error, created_at)
      VALUES (?1, ?2, 'queued', 1, ?3, ?4, ?5)
      """,
      [
        peer_id,
        Jason.encode!(envelope),
        now |> DateTime.add(backoff(1), :second) |> DateTime.to_iso8601(),
        inspect_error(last_error),
        DateTime.to_iso8601(now)
      ]
    )

    :ok
  end

  @doc """
  Deliver every due queued envelope once. Public so tests (and a manual
  console poke) can drive the queue without waiting for the tick.
  """
  @spec deliver_due() :: :ok
  def deliver_due do
    now = DateTime.utc_now()

    case Store.query(
           """
           SELECT id, peer, envelope_json, attempts, created_at FROM outbound_queue
           WHERE state = 'queued' AND next_attempt_at <= ?1
           ORDER BY peer, created_at, id LIMIT ?2
           """,
           [DateTime.to_iso8601(now), @batch]
         ) do
      {:ok, rows} ->
        rows
        |> Enum.chunk_by(fn [_id, peer | _] -> peer end)
        |> Enum.each(&deliver_peer_batch(&1, now))

      _ ->
        :ok
    end

    :ok
  end

  @doc "Queued and dead rows grouped per peer, for the owner's delivery report."
  @spec status() :: [map()]
  def status do
    case Store.query("""
         SELECT peer, state, COUNT(*), MIN(created_at), MAX(last_error)
         FROM outbound_queue WHERE state IN ('queued', 'dead')
         GROUP BY peer, state ORDER BY peer
         """) do
      {:ok, rows} ->
        Enum.map(rows, fn [peer, state, count, oldest, last_error] ->
          %{peer: peer, state: state, count: count, oldest: oldest, last_error: last_error}
        end)

      _ ->
        []
    end
  end

  # --- Server ---

  @impl true
  def init(_) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    deliver_due()
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_tick do
    ms = Application.get_env(:kbase_bot, :federation_queue_tick_ms, @default_tick_ms)
    Process.send_after(self(), :tick, ms)
  end

  # --- delivery ---

  # In-order per peer: the first failure parks the rest of this peer's batch.
  defp deliver_peer_batch(rows, now) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case deliver_row(row, now) do
        :delivered -> {:cont, :ok}
        _ -> {:halt, :failed}
      end
    end)
  end

  defp deliver_row([id, peer, envelope_json, attempts, created_at], now) do
    envelope = Jason.decode!(envelope_json)

    case attempt(envelope, peer) do
      :ok ->
        Store.execute(
          "UPDATE outbound_queue SET state = 'delivered', delivered_at = ?1 WHERE id = ?2",
          [DateTime.to_iso8601(now), id]
        )

        # Delivery went through — re-arm the unreachable alert for this peer.
        Store.execute("DELETE FROM peer_delivery_alerts WHERE peer = ?1", [peer])
        :delivered

      {:error, reason} ->
        age_s = row_age_s(created_at, now)
        attempts = attempts + 1

        if age_s > @max_age_s do
          Store.execute(
            "UPDATE outbound_queue SET state = 'dead', attempts = ?1, last_error = ?2 WHERE id = ?3",
            [attempts, inspect_error(reason), id]
          )

          Logger.warning("Federation queue: envelope to #{peer} dead-lettered after 7 days")
        else
          next =
            now |> DateTime.add(backoff(attempts), :second) |> DateTime.to_iso8601()

          Store.execute(
            """
            UPDATE outbound_queue SET attempts = ?1, next_attempt_at = ?2, last_error = ?3
            WHERE id = ?4
            """,
            [attempts, next, inspect_error(reason), id]
          )
        end

        maybe_alert_unreachable(peer, now)
        :failed
    end
  end

  # Same endpoint walk as Outbound's first attempt, minus the re-enqueue.
  @doc false
  def attempt(envelope, peer_id) do
    with {:ok, %{card: card}} <- Contacts.find(peer_id) do
      endpoints =
        (card["endpoints"] || [])
        |> Enum.sort_by(fn ep -> ep["priority"] || 99 end)

      try_endpoints(envelope, endpoints, {:error, :no_transport})
    else
      _ -> {:error, :unknown_contact}
    end
  end

  defp try_endpoints(_envelope, [], last_error), do: last_error

  defp try_endpoints(envelope, [endpoint | rest], last_error) do
    case Transport.adapter(endpoint["transport"]) do
      nil ->
        try_endpoints(envelope, rest, last_error)

      adapter ->
        case adapter.deliver(envelope, endpoint) do
          :ok -> :ok
          {:error, reason} -> try_endpoints(envelope, rest, {:error, reason})
        end
    end
  end

  defp maybe_alert_unreachable(peer, now) do
    threshold_s =
      Application.get_env(
        :kbase_bot,
        :federation_unreachable_alert_s,
        @default_unreachable_alert_s
      )

    with {:ok, [[oldest]]} when is_binary(oldest) <-
           Store.query(
             "SELECT MIN(created_at) FROM outbound_queue WHERE peer = ?1 AND state = 'queued'",
             [peer]
           ),
         true <- row_age_s(oldest, now) > threshold_s,
         {:ok, []} <-
           Store.query("SELECT peer FROM peer_delivery_alerts WHERE peer = ?1", [peer]) do
      Store.execute(
        "INSERT OR REPLACE INTO peer_delivery_alerts (peer, alerted_at) VALUES (?1, ?2)",
        [peer, DateTime.to_iso8601(now)]
      )

      OwnerNotifier.notify_owner(
        "[Federation] #{peer_name(peer)} has been unreachable for over " <>
          "#{div(threshold_s, 86_400)} day(s) — envelopes are queued and will keep retrying " <>
          "for 7 days from submission."
      )
    else
      _ -> :ok
    end
  end

  defp row_age_s(created_at, now) do
    case DateTime.from_iso8601(created_at) do
      {:ok, dt, _} -> DateTime.diff(now, dt, :second)
      _ -> 0
    end
  end

  defp backoff(attempts) do
    min(@backoff_base_s * Integer.pow(2, min(attempts, 16) - 1), @backoff_cap_s)
  end

  defp inspect_error(nil), do: nil
  defp inspect_error(reason), do: reason |> inspect() |> String.slice(0, 200)

  defp peer_name(principal_id) do
    case Contacts.find(principal_id) do
      {:ok, %{display_name: name}} when is_binary(name) -> "#{name} (#{principal_id})"
      _ -> principal_id
    end
  end
end
