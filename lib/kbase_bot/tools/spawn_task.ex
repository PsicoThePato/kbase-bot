defmodule KbaseBot.Tools.SpawnTask do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "spawn_task"

  @impl true
  def description do
    "Create a new background task for complex questions that require searching the knowledge base. The task runs independently and the user will be notified when it completes."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        description: %{
          type: "string",
          description: "Clear description of what the task should accomplish"
        }
      },
      required: ["description"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, _context) do
    # Handled directly by Manager.handle_spawn_task/2
    {:error, "spawn_task must be handled by Manager"}
  end
end
