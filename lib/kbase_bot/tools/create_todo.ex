defmodule KbaseBot.Tools.CreateTodo do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "create_todo"

  @impl true
  def description do
    "Create a todo in Todoist. Supports natural language due dates like 'tomorrow at 3pm', 'every monday', 'next friday'. Priority 1 (normal) to 4 (urgent)."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        content: %{type: "string", description: "The task content"},
        due: %{
          type: "string",
          description:
            "Natural language due date, e.g. 'tomorrow at 3pm', 'every monday', 'in 2 hours'"
        },
        priority: %{type: "integer", description: "Priority 1 (normal) to 4 (urgent)"}
      },
      required: ["content"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(input, _context) do
    content = input["content"]

    opts =
      %{}
      |> maybe_put("due_string", input["due"])
      |> maybe_put("priority", input["priority"])

    case KbaseBot.Todoist.Client.create_task(content, opts) do
      {:ok, task} ->
        due_info = if task["due"], do: " — due: #{task["due"]["string"]}", else: ""
        {:ok, "Todo created: \"#{task["content"]}\"#{due_info} (id: #{task["id"]})"}

      {:error, reason} ->
        {:error, "Failed to create todo: #{reason}"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
