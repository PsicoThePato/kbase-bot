defmodule KbaseBot.Tools.ReadFile do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "read_file"

  @impl true
  def description do
    "Read the full contents of a specific file from the knowledge base by relative path."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Relative file path from repo root, e.g. nutrition/05-weekly-meal-plan.md"
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def layer, do: :task

  @impl true
  def execute(%{"path" => path}, context) do
    repo_path = KbaseBot.Context.Server.repo_path()
    full_path = Path.join(repo_path, path)

    # Prevent path traversal. The trailing separator matters: without it,
    # a sibling like /data/knowledge_base_secret passes the prefix check
    # against repo /data/knowledge_base.
    if String.starts_with?(Path.expand(full_path), Path.expand(repo_path) <> "/") do
      case File.read(full_path) do
        {:ok, content} ->
          # Deny by default: an ungranted file is indistinguishable from a
          # missing one.
          if KbaseBot.Policy.can_read_file?(context[:principal], path, content) do
            {:ok, content}
          else
            {:error, "File not found: #{path}"}
          end

        {:error, :enoent} ->
          {:error, "File not found: #{path}"}

        {:error, reason} ->
          {:error, "Cannot read #{path}: #{inspect(reason)}"}
      end
    else
      {:error, "Path traversal not allowed"}
    end
  end
end
