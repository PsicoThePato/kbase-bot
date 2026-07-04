defmodule KbaseBot.Tools.MessageTask do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "message_task"

  @impl true
  def description do
    "Send a follow-up message to a completed or failed task to resume it with new instructions."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        task_id: %{type: "string", description: "The task ID"},
        message: %{type: "string", description: "The follow-up message to send"}
      },
      required: ["task_id", "message"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, _context) do
    # Handled directly by Manager.handle_message_task/2
    {:error, "message_task must be handled by Manager"}
  end
end
