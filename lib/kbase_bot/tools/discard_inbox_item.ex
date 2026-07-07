defmodule KbaseBot.Tools.DiscardInboxItem do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.TrustSignals
  alias KbaseBot.KB.Frontmatter

  @impl true
  def name, do: "discard_inbox_item"

  @impl true
  def description do
    "Delete a quarantined inbox item the owner doesn't want. Logs a negative trust signal for the pushing peer on that topic."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "The inbox item path from review_inbox"
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"path" => path}, context) do
    with :ok <- KbaseBot.Tool.require_owner(context),
         {:ok, full, rel, topic} <- resolve_inbox_path(path) do
      source = source_principal(full)

      case File.rm(full) do
        :ok ->
          TrustSignals.log(source, topic, rel, "discard")
          {:ok, "Discarded #{rel}. Trust signal logged: discard for #{source}/#{topic}."}

        {:error, reason} ->
          {:error, "could not delete: #{inspect(reason)}"}
      end
    end
  end

  @doc false
  # Shared with promote_inbox_item: the path must resolve to a real .md file
  # strictly inside inbox/ (no traversal out of the quarantine).
  def resolve_inbox_path(path) do
    root = KbaseBot.Context.Server.repo_path()
    full = Path.expand(Path.join(root, path))
    inbox_root = Path.expand(Path.join(root, "inbox"))
    rel = Path.relative_to(full, root)

    cond do
      not String.starts_with?(full, inbox_root <> "/") ->
        {:error, "path must be inside inbox/ (see review_inbox)"}

      Path.extname(full) != ".md" or not File.regular?(full) ->
        {:error, "no such inbox item: #{path}"}

      true ->
        {:ok, full, rel, rel |> Path.split() |> Enum.at(1, "misc")}
    end
  end

  defp source_principal(full) do
    with {:ok, content} <- File.read(full),
         {:ok, meta, _} <- Frontmatter.parse(content),
         principal when is_binary(principal) <- get_in(meta, ["source", "principal"]) do
      principal
    else
      _ -> "unknown"
    end
  end
end
