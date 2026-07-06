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
    require Logger

    if not Application.get_env(:kbase_bot, :qmd_enabled, true) do
      {:error, "QMD is disabled (QMD_ENABLED=false). Knowledge base search is unavailable."}
    else
      Logger.debug("QMD search query: #{query}")

      qmd = Application.get_env(:kbase_bot, :qmd_path, "qmd")

      case System.cmd(qmd, ["query", query, "--json"], stderr_to_stdout: true) do
        {output, 0} ->
          Logger.debug("QMD search result: #{byte_size(output)} bytes")

          if KbaseBot.Principal.owner?(context[:principal]) do
            {:ok, output}
          else
            # The semantic index is global; post-filter results by the
            # requesting principal's grants before any LLM sees them.
            {:ok, filter_results(output, context[:principal])}
          end

        {output, code} ->
          Logger.warning("QMD search exit code #{code}: #{output}")
          {:error, "QMD search failed: #{output}"}
      end
    end
  rescue
    e -> {:error, "QMD not available: #{inspect(e)}"}
  end

  # QMD mixes progress/warning lines into stdout before the JSON array
  # (stderr_to_stdout) — parse from the first "[". Entries are dropped
  # wholesale when the file isn't readable by the principal (snippets carry
  # content). Any parse failure returns [] — fail closed.
  defp filter_results(output, principal) do
    repo_path = KbaseBot.Context.Server.repo_path()

    with {pos, _len} <- :binary.match(output, "["),
         json = binary_part(output, pos, byte_size(output) - pos),
         {:ok, entries} when is_list(entries) <- Jason.decode(json) do
      entries
      |> Enum.filter(fn entry ->
        with rel when is_binary(rel) <- qmd_rel_path(entry["file"]),
             {:ok, content} <- File.read(Path.join(repo_path, rel)) do
          KbaseBot.Policy.can_read_file?(principal, rel, content)
        else
          _ -> false
        end
      end)
      |> Jason.encode!()
    else
      _ -> "[]"
    end
  end

  # "qmd://knowledge_base/nutrition/x.md" -> "nutrition/x.md"
  defp qmd_rel_path("qmd://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [_collection, rel] -> rel
      _ -> nil
    end
  end

  defp qmd_rel_path(_), do: nil
end
