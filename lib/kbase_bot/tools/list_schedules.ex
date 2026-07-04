defmodule KbaseBot.Tools.ListSchedules do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "list_schedules"

  @impl true
  def description,
    do:
      "List all active schedules with their cron expression, payload summary, and next fire time."

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, _context) do
    case KbaseBot.Repo.Store.query(
           "SELECT id, cron, payload, timezone, next_fire_at, fire_count FROM schedules WHERE state = 'active' ORDER BY next_fire_at ASC"
         ) do
      {:ok, []} ->
        {:ok, "No active schedules."}

      {:ok, rows} ->
        lines =
          Enum.map(rows, fn [id, cron, payload, timezone, next_fire, fire_count] ->
            summary = String.slice(payload, 0, 80)

            "- #{id} | cron: #{cron} (#{timezone}) | next: #{next_fire} | fired: #{fire_count}x\n  #{summary}"
          end)

        {:ok, Enum.join(lines, "\n")}

      {:error, reason} ->
        {:error, "Failed to list schedules: #{inspect(reason)}"}
    end
  end
end
