defmodule KbaseBot.Tools.DeleteTodo do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "delete_todo"

  @impl true
  def description do
    "Delete a Todoist task permanently. Use list_todos first to find the task ID."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        task_id: %{type: "string", description: "The Todoist task ID to delete"}
      },
      required: ["task_id"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"task_id" => id}, _context) do
    case KbaseBot.Todoist.Client.delete_task(id) do
      :ok -> {:ok, "Todo #{id} deleted."}
      {:error, reason} -> {:error, "Failed to delete todo: #{reason}"}
    end
  end
end
