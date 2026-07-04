defmodule KbaseBot.Tools.UpdateSchedule do
  @behaviour KbaseBot.Tool

  alias KbaseBot.Scheduler.Cron

  @impl true
  def name, do: "update_schedule"

  @impl true
  def description, do: "Update an existing schedule's cron expression or payload."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        schedule_id: %{type: "string", description: "The schedule ID to update"},
        cron: %{type: "string", description: "New cron expression (optional)"},
        payload: %{type: "string", description: "New payload text (optional)"}
      },
      required: ["schedule_id"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(input, _context) do
    id = input["schedule_id"]
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case KbaseBot.Repo.Store.query(
           "SELECT cron, payload, timezone FROM schedules WHERE id = ?1",
           [id]
         ) do
      {:ok, [[current_cron, current_payload, timezone]]} ->
        new_cron = Map.get(input, "cron", current_cron)
        new_payload = Map.get(input, "payload", current_payload)

        after_dt = DateTime.now!(timezone || "America/Sao_Paulo") |> DateTime.add(60)

        case Cron.next_fire_at(new_cron, timezone, after_dt) do
          {:ok, next_fire} ->
            KbaseBot.Repo.Store.execute(
              "UPDATE schedules SET cron = ?1, payload = ?2, next_fire_at = ?3, updated_at = ?4 WHERE id = ?5",
              [new_cron, new_payload, next_fire, now, id]
            )

            {:ok, "Schedule #{id} updated. Next fire: #{next_fire}"}

          {:error, reason} ->
            {:error, "Invalid cron expression: #{inspect(reason)}"}
        end

      {:ok, []} ->
        {:error, "Schedule #{id} not found."}

      {:error, reason} ->
        {:error, "Failed: #{inspect(reason)}"}
    end
  end
end
