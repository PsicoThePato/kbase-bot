defmodule KbaseBot.Tools.ReviewInbox do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.KB.Frontmatter

  @impl true
  def name, do: "review_inbox"

  @impl true
  def description do
    "List quarantined inbox items (peer-pushed content awaiting the owner's verdict), with source peer and topic. Follow up with promote_inbox_item or discard_inbox_item — each verdict also trains future per-peer trust."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        topic: %{type: "string", description: "Limit to one inbox topic (directory)"}
      }
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case items(input["topic"]) do
        [] ->
          {:ok, "Inbox is empty."}

        items ->
          lines =
            Enum.map_join(items, "\n", fn item ->
              "- #{item.path} — from #{item.source}#{title_note(item.title)}"
            end)

          {:ok, "#{length(items)} inbox item(s):\n#{lines}"}
      end
    end
  end

  @doc false
  def items(topic \\ nil) do
    root = KbaseBot.Context.Server.repo_path()
    pattern = if topic, do: "inbox/#{topic}/*.md", else: "inbox/**/*.md"

    root
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn full ->
      rel = Path.relative_to(full, root)
      meta = read_meta(full)

      %{
        path: rel,
        topic: rel |> Path.split() |> Enum.at(1, "misc"),
        source: get_in(meta, ["source", "principal"]) || "unknown",
        title: meta["name"]
      }
    end)
  end

  defp read_meta(full) do
    with {:ok, content} <- File.read(full),
         {:ok, meta, _body} <- Frontmatter.parse(content) do
      meta
    else
      _ -> %{}
    end
  end

  defp title_note(nil), do: ""
  defp title_note(title), do: " — “#{title}”"
end
