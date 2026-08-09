defmodule KbaseBot.Tools.SearchKnowledge do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "search_knowledge"

  @impl true
  def description do
    "Search the personal knowledge base for relevant information using semantic and keyword search. Returns the most relevant text chunks."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Search query describing what information you need"}
      },
      required: ["query"]
    }
  end

  @impl true
  def layer, do: :task

  @impl true
  def execute(%{"query" => query}, context) do
    {:ok, hits} = KbaseBot.KB.Search.search(query)

    hits =
      if KbaseBot.Principal.owner?(context[:principal]) do
        hits
      else
        # The search index is global; drop hits wholesale before any LLM sees
        # them when the file isn't readable by the principal (excerpts carry
        # content). Any read failure drops the hit — fail closed.
        filter_hits(hits, context[:principal])
      end

    {:ok, Jason.encode!(hits)}
  end

  defp filter_hits(hits, principal) do
    repo_path = KbaseBot.Context.Server.repo_path()

    Enum.filter(hits, fn %{file: rel} ->
      case File.read(Path.join(repo_path, rel)) do
        {:ok, content} -> KbaseBot.Policy.can_read_file?(principal, rel, content)
        _ -> false
      end
    end)
  end
end
