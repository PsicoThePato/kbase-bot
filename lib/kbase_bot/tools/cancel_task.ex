defmodule KbaseBot.Tools.CancelTask do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "cancel_task"

  @impl true
  def description do
    "Cancel a running or active task. The task will be marked as failed with 'cancelled'."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        task_id: %{type: "string", description: "The task ID to cancel"}
      },
      required: ["task_id"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, _context) do
    # Handled directly by Manager.handle_cancel_task/2
    {:error, "cancel_task must be handled by Manager"}
  end
end
