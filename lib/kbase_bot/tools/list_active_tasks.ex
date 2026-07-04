defmodule KbaseBot.Tools.ListActiveTasks do
  @behaviour KbaseBot.Tool

  alias KbaseBot.Tasks.Task

  @impl true
  def name, do: "list_active_tasks"

  @impl true
  def description do
    "List all active background tasks (pending, planning, or executing). Returns their current state and description."
  end

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :manager

  @impl true
  def execute(_input, _context) do
    tasks = Task.find_active()

    if tasks == [] do
      {:ok, "No active tasks."}
    else
      lines =
        Enum.map(tasks, fn task ->
          input = List.first(task.messages)
          desc = if input, do: input["content"], else: "(no description)"
          desc = String.slice(to_string(desc), 0, 100)
          "- #{task.id} [#{task.state}] #{desc}"
        end)

      {:ok, Enum.join(lines, "\n")}
    end
  end
end
