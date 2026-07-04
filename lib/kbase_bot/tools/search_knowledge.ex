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
  def execute(%{"query" => query}, _context) do
    require Logger

    if not Application.get_env(:kbase_bot, :qmd_enabled, true) do
      {:error, "QMD is disabled (QMD_ENABLED=false). Knowledge base search is unavailable."}
    else
      Logger.debug("QMD search query: #{query}")

      qmd = Application.get_env(:kbase_bot, :qmd_path, "qmd")

      case System.cmd(qmd, ["query", query, "--json"], stderr_to_stdout: true) do
        {output, 0} ->
          Logger.debug("QMD search result: #{byte_size(output)} bytes")
          {:ok, output}

        {output, code} ->
          Logger.warning("QMD search exit code #{code}: #{output}")
          {:error, "QMD search failed: #{output}"}
      end
    end
  rescue
    e -> {:error, "QMD not available: #{inspect(e)}"}
  end
end
