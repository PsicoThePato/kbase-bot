defmodule KbaseBot.Tools.ReadTaskDetails do
  @behaviour KbaseBot.Tool

  alias KbaseBot.Tasks.Task

  @impl true
  def name, do: "read_task_details"

  @impl true
  def description do
    "Read the full details of a task: its state, plan, result, and error. Use when the user asks for more information about a specific task."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        task_id: %{type: "string", description: "The task ID"}
      },
      required: ["task_id"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"task_id" => task_id}, _context) do
    case Task.find(task_id) do
      {:ok, task} ->
        result_text =
          case task.outcome do
            {:success, text} -> "Result: #{text}"
            {:failed, reason} -> "Failed: #{reason}"
            nil -> "No outcome yet"
          end

        {:ok,
         """
         Task: #{task.id}
         State: #{task.state}
         Type: #{task.task_type}
         Plan: #{task.plan || "(none)"}
         Status: #{task.status_message || "(none)"}
         #{result_text}
         Created: #{task.created_at}
         """}

      {:error, :not_found} ->
        {:error, "Task #{task_id} not found."}
    end
  end
end
