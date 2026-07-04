defmodule KbaseBot.Tools.CompleteTodo do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "complete_todo"

  @impl true
  def description do
    "Mark a Todoist task as complete. Use list_todos first to find the task ID if needed."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        task_id: %{type: "string", description: "The Todoist task ID to complete"}
      },
      required: ["task_id"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"task_id" => id}, _context) do
    case KbaseBot.Todoist.Client.close_task(id) do
      :ok -> {:ok, "Todo #{id} completed."}
      {:error, reason} -> {:error, "Failed to complete todo: #{reason}"}
    end
  end
end
