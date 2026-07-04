defmodule KbaseBot.Tools.SearchHistory do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "search_history"

  @impl true
  def description do
    "Search past conversation history for relevant context using semantic search. Use when the user references something from a previous conversation or you need background context that's not in the current window."
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
    case KbaseBot.Memory.Embedder.search(query, "message", 5) do
      {:ok, []} ->
        {:ok, "No relevant conversation history found."}

      {:ok, results} ->
        formatted =
          results
          |> Enum.map(fn %{role: role, content: content, created_at: created_at, score: score} ->
            "- [#{created_at}] #{role}: #{String.slice(content, 0, 300)} (relevance: #{Float.round(score, 3)})"
          end)
          |> Enum.join("\n")

        {:ok, formatted}

      {:error, reason} ->
        {:error, "History search failed: #{inspect(reason)}"}
    end
  end
end
