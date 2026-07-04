defmodule KbaseBot.Tools.CancelSchedule do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "cancel_schedule"

  @impl true
  def description, do: "Cancel an active schedule by its ID. The schedule will stop firing."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        schedule_id: %{type: "string", description: "The schedule ID to cancel"}
      },
      required: ["schedule_id"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"schedule_id" => id}, _context) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    KbaseBot.Repo.Store.execute(
      "UPDATE schedules SET state = 'completed', updated_at = ?1 WHERE id = ?2",
      [now, id]
    )

    {:ok, "Schedule #{id} cancelled."}
  end
end
