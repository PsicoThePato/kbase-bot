defmodule KbaseBot.Tools.SearchTasks do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "search_tasks"

  @impl true
  def description do
    "Search completed background tasks for relevant context using semantic search. Use when the user asks about something a previous task researched or worked on."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Natural language search query"}
      },
      required: ["query"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"query" => query}, _context) do
    case KbaseBot.Memory.Embedder.search(query, "task", 5) do
      {:ok, []} ->
        {:ok, "No relevant past tasks found."}

      {:ok, results} ->
        formatted =
          results
          |> Enum.map(fn result ->
            outcome_text =
              if result[:outcome],
                do: "\n  Outcome: #{String.slice(result.outcome, 0, 300)}",
                else: ""

            "- [#{result[:created_at]}] #{result[:state]} — #{String.slice(result[:description] || "", 0, 200)}#{outcome_text} (relevance: #{Float.round(result.score, 3)})"
          end)
          |> Enum.join("\n")

        {:ok, formatted}

      {:error, reason} ->
        {:error, "Task search failed: #{inspect(reason)}"}
    end
  end
end
