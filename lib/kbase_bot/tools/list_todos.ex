defmodule KbaseBot.Tools.ListTodos do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "list_todos"

  @impl true
  def description do
    "List all active todos from Todoist. Use when the user asks what they need to do, or to find a task ID before completing/deleting it."
  end

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, _context) do
    case KbaseBot.Todoist.Client.list_tasks() do
      {:ok, []} ->
        {:ok, "No active todos."}

      {:ok, tasks} ->
        lines =
          Enum.map(tasks, fn task ->
            due = if task["due"], do: " — due: #{task["due"]["string"]}", else: ""
            priority = if task["priority"] > 1, do: " [p#{task["priority"]}]", else: ""
            "- #{task["content"]}#{due}#{priority} (id: #{task["id"]})"
          end)

        {:ok, Enum.join(lines, "\n")}

      {:error, reason} ->
        {:error, "Failed to list todos: #{reason}"}
    end
  end
end
