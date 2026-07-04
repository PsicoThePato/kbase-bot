defmodule KbaseBot.Scheduler.Scheduler do
  @moduledoc """
  Polls the schedules table and fires due schedules into the Manager.
  Adapted from aifred-web's reminder_scheduler worker.
  """
  use GenServer

  require Logger

  alias KbaseBot.Scheduler.Cron

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    poll_interval = Application.get_env(:kbase_bot, :scheduler_poll_interval_ms, 15_000)
    Process.send_after(self(), :poll, poll_interval)
    {:ok, %{poll_interval: poll_interval}}
  end

  @impl true
  def handle_info(:poll, state) do
    fire_due_schedules()
    Process.send_after(self(), :poll, state.poll_interval)
    {:noreply, state}
  end

  defp fire_due_schedules do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case KbaseBot.Repo.Store.query(
           "SELECT id, payload, cron, timezone, max_fires, fire_count FROM schedules WHERE state = 'active' AND next_fire_at IS NOT NULL AND next_fire_at <= ?1",
           [now]
         ) do
      # TODO: harden scheduling — consider edge cases like missed fires,
      # manager crashes, and concurrent poll overlap. Evaluate whether
      # extended cron (second resolution) or a proper job queue is needed.
      {:ok, rows} when rows != [] ->
        Enum.each(rows, fn [id, payload, cron, timezone, max_fires, fire_count] ->
          Logger.info("Schedule #{id} firing")

          new_fire_count = (fire_count || 0) + 1

          # Advance next_fire_at BEFORE firing to prevent duplicate fires
          # within the same cron minute window
          db_result =
            if max_fires != nil and new_fire_count >= max_fires do
              Logger.info("Schedule #{id} completed (reached max_fires: #{max_fires})")

              KbaseBot.Repo.Store.execute(
                "UPDATE schedules SET last_fired_at = ?1, fire_count = ?2, state = 'completed', updated_at = ?1 WHERE id = ?3",
                [now, new_fire_count, id]
              )
            else
              fired_at =
                DateTime.now!(timezone || "America/Sao_Paulo")
                |> DateTime.add(60)

              next =
                case Cron.next_fire_at(cron, timezone, fired_at) do
                  {:ok, dt} -> dt
                  {:error, _} -> nil
                end

              KbaseBot.Repo.Store.execute(
                "UPDATE schedules SET last_fired_at = ?1, fire_count = ?2, next_fire_at = ?3, updated_at = ?1 WHERE id = ?4",
                [now, new_fire_count, next, id]
              )
            end

          case db_result do
            :ok ->
              KbaseBot.Manager.schedule_fire(payload)

            {:error, reason} ->
              Logger.error(
                "Schedule #{id} failed to advance next_fire_at: #{inspect(reason)}, skipping fire"
              )
          end
        end)

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Scheduler poll failed: #{inspect(reason)}")
    end
  end
end
