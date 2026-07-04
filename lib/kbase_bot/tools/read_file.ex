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
  def execute(%{"path" => path}, _context) do
    repo_path = KbaseBot.Context.Server.repo_path()
    full_path = Path.join(repo_path, path)

    # Prevent path traversal
    if String.starts_with?(Path.expand(full_path), Path.expand(repo_path)) do
      case File.read(full_path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:error, "File not found: #{path}"}
        {:error, reason} -> {:error, "Cannot read #{path}: #{inspect(reason)}"}
      end
    else
      {:error, "Path traversal not allowed"}
    end
  end
end
