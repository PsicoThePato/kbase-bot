defmodule KbaseBot.Tools.PromoteInboxItem do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.TrustSignals
  alias KbaseBot.KB.Frontmatter

  @impl true
  def name, do: "promote_inbox_item"

  @impl true
  def description do
    "Promote a quarantined inbox item into the knowledge base proper (moves the file; content stays attributed to its source and scoped [private] until the owner relabels it). Logs a positive trust signal for the pushing peer on that topic."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "The inbox item path from review_inbox, e.g. inbox/movies/2026-...md"
        },
        dest_dir: %{
          type: "string",
          description:
            "Destination directory relative to the KB root (default: the topic name, e.g. movies/)"
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"path" => path} = input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context),
         {:ok, full, rel, topic} <- KbaseBot.Tools.DiscardInboxItem.resolve_inbox_path(path),
         {:ok, dest_rel} <- resolve_dest(input["dest_dir"], topic, rel) do
      root = KbaseBot.Context.Server.repo_path()
      dest_full = Path.join(root, dest_rel)
      File.mkdir_p!(Path.dirname(dest_full))

      source = source_principal(full)

      case File.rename(full, dest_full) do
        :ok ->
          TrustSignals.log(source, topic, rel, "promote")

          {:ok,
           "Promoted to #{dest_rel} (still scoped [private] and attributed to " <>
             "#{source} — relabel its scopes yourself if it should be shareable). " <>
             "Trust signal logged: promote for #{source}/#{topic}."}

        {:error, reason} ->
          {:error, "could not move file: #{inspect(reason)}"}
      end
    end
  end

  # Default destination mirrors the topic: inbox/movies/x.md → movies/x.md.
  defp resolve_dest(dest_dir, topic, rel) do
    dir = dest_dir || topic
    dest_rel = Path.join(dir, Path.basename(rel))
    root = KbaseBot.Context.Server.repo_path()
    expanded = Path.expand(Path.join(root, dest_rel))

    cond do
      not String.starts_with?(expanded, Path.expand(root)) ->
        {:error, "destination escapes the knowledge base"}

      String.starts_with?(dest_rel, "inbox/") ->
        {:error, "destination must be outside inbox/ — that's what promotion means"}

      true ->
        {:ok, dest_rel}
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
