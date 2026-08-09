defmodule KbaseBot.Tools.InboxAppend do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "inbox_append"

  @impl true
  def description do
    "File an item into the quarantine inbox (inbox/<topic>/) as quoted, attributed content. This is your ONLY write; the main knowledge base is out of reach. The owner reviews and promotes inbox items themselves."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        title: %{type: "string", description: "Short title for the filed item"},
        content: %{
          type: "string",
          description: "The item content (or your summary of it), markdown"
        },
        note: %{type: "string", description: "One line on why this is worth the owner's time"}
      },
      required: ["title", "content"]
    }
  end

  @impl true
  def layer, do: :federation

  @impl true
  def execute(%{"title" => title, "content" => content} = input, context) do
    publisher = context[:publisher_id] || "unknown"
    topic = sanitize(context[:topic] || "misc")

    date = Date.utc_today() |> Date.to_iso8601()
    suffix = :crypto.strong_rand_bytes(3) |> Base.url_encode64(padding: false)
    filename = "#{date}-#{sanitize(title)}-#{suffix}.md"
    rel_path = Path.join(["inbox", topic, filename])

    # Quoted, attributed, never owner voice — and private, so no grant can
    # re-export it before the owner promotes it.
    file_content = """
    ---
    name: #{title}
    source: {principal: "#{publisher}", received: #{date}}
    scopes: [private]
    ---

    > Pushed by #{publisher}#{note_line(input["note"])}

    #{content}
    """

    case KbaseBot.KB.Writer.write(rel_path, file_content,
           actor: "peer:#{publisher}",
           source: "inbox_append",
           meta: %{topic: topic}
         ) do
      {:ok, _} -> {:ok, "Filed to #{rel_path}"}
      {:error, reason} -> {:error, "could not file item: #{inspect(reason)}"}
    end
  end

  defp note_line(nil), do: ""
  defp note_line(note), do: " — #{note}"

  # Kills path traversal: only [a-z0-9_-] survives, so a hostile topic or
  # title can never escape inbox/.
  defp sanitize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 48)
    |> case do
      "" -> "item"
      slug -> slug
    end
  end
end
