defmodule KbaseBot.Tools.ListFiles do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "list_files"

  @impl true
  def description do
    "List the file tree of the knowledge base. Use this first to discover which files exist and their exact paths before using read_file."
  end

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :task

  @impl true
  def execute(_input, _context) do
    repo_path = KbaseBot.Context.Server.repo_path()

    tree =
      repo_path
      |> list_tree("")
      |> Enum.sort()
      |> Enum.join("\n")

    {:ok, tree}
  end

  defp list_tree(base_path, rel_path) do
    full_path = Path.join(base_path, rel_path)

    case File.ls(full_path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&skip?/1)
        |> Enum.flat_map(fn entry ->
          entry_rel = if rel_path == "", do: entry, else: Path.join(rel_path, entry)
          entry_full = Path.join(base_path, entry_rel)

          if File.dir?(entry_full) do
            list_tree(base_path, entry_rel)
          else
            [entry_rel]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp skip?(name) do
    name in [".git", "kbase_bot", "node_modules", ".DS_Store"] or
      String.ends_with?(name, ".age")
  end
end
