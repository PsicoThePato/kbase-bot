defmodule KbaseBot.Tools.CreateSchedule do
  @behaviour KbaseBot.Tool

  alias KbaseBot.Scheduler.Cron

  @impl true
  def name, do: "create_schedule"

  @impl true
  def description do
    "Create a schedule. When it fires, the payload text is injected into the conversation. Use for reminders, daily briefings, or any recurring/one-time event. Set max_fires to 1 for one-time schedules. If a similar payload already exists on an active schedule, you'll get a warning with its ID — set force=true to create anyway if they are genuinely different."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        cron: %{
          type: "string",
          description:
            "Cron expression (5-field: minute hour day month weekday). Examples: '0 8 * * *' (daily at 8 AM), '0 15 * * 1-5' (weekdays at 3 PM), '30 14 * * *' (daily at 2:30 PM)"
        },
        payload: %{
          type: "string",
          description: "The instruction text that will be injected when the schedule fires"
        },
        timezone: %{
          type: "string",
          description: "Timezone (default: America/Sao_Paulo)"
        },
        max_fires: %{
          type: "integer",
          description:
            "Maximum number of times to fire. Omit for unlimited (recurring). Set to 1 for one-time."
        },
        force: %{
          type: "boolean",
          description: "Set to true to bypass the similar payload check"
        }
      },
      required: ["cron", "payload"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(input, _context) do
    cron = input["cron"]
    payload = input["payload"]
    timezone = Map.get(input, "timezone", "America/Sao_Paulo")
    max_fires = Map.get(input, "max_fires")

    force = Map.get(input, "force", false)

    case {force, check_existing(payload)} do
      {false, {:conflict, id, existing_payload}} ->
        {:error,
         "Similar active schedule found (id: #{id}, payload: \"#{String.slice(existing_payload, 0, 80)}\"). Cancel it, use update_schedule, or set force=true to create anyway."}

      _ ->
        case Cron.next_fire_at(cron, timezone) do
          {:ok, next_fire} ->
            id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
            now = DateTime.utc_now() |> DateTime.to_iso8601()

            KbaseBot.Repo.Store.execute(
              """
              INSERT INTO schedules (id, payload, cron, timezone, next_fire_at, max_fires, state, created_at, updated_at)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active', ?7, ?7)
              """,
              [id, payload, cron, timezone, next_fire, max_fires, now]
            )

            suffix = if max_fires, do: " (fires #{max_fires}x)", else: " (recurring)"
            {:ok, "Schedule #{id} created. Next fire: #{next_fire}. Cron: #{cron}#{suffix}"}

          {:error, reason} ->
            {:error, "Invalid cron expression: #{inspect(reason)}"}
        end
    end
  end

  defp check_existing(payload) do
    case KbaseBot.Repo.Store.query("SELECT id, payload FROM schedules WHERE state = 'active'") do
      {:ok, rows} ->
        conflict =
          Enum.find(rows, fn [_id, existing_payload] ->
            similar_payload?(existing_payload, payload)
          end)

        case conflict do
          [id, existing_payload] -> {:conflict, id, existing_payload}
          nil -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp similar_payload?(existing, new) do
    normalize = fn text ->
      text |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
    end

    normalized_existing = normalize.(existing)
    normalized_new = normalize.(new)

    String.jaro_distance(normalized_existing, normalized_new) > 0.85
  end
end
