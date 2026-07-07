defmodule KbaseBot.Tools.ReviewDisclosures do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Contacts, Disclosures}

  @impl true
  def name, do: "review_disclosures"

  @impl true
  def description do
    "Audit what this bot actually sent to peers: per-(peer, scope) counts of answers, discussion turns, published items and outbound questions in a time window, plus the most recent entries with content summaries."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{
          type: "string",
          description: "Limit to one peer (omit for all peers)"
        },
        days: %{type: "integer", description: "Window in days (default 30)"}
      }
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      peer = input["principal_id"]
      days = input["days"] || 30

      case Disclosures.summary(peer, days) do
        [] ->
          {:ok, "No disclosures to #{peer || "any peer"} in the last #{days} days."}

        summary ->
          rollup =
            Enum.map_join(summary, "\n", fn row ->
              "- #{display(row.peer)} · #{row.scope || "?"} · #{row.kind}: #{row.count}"
            end)

          recent =
            Disclosures.recent(peer, days, 10)
            |> Enum.map_join("\n", fn d ->
              date = String.slice(d.created_at, 0, 10)

              "- #{date} #{d.kind} → #{display(d.peer)} (#{d.scope || "?"}): " <>
                one_line(d.summary)
            end)

          {:ok, "Disclosures, last #{days} days:\n#{rollup}\n\nMost recent:\n#{recent}"}
      end
    end
  end

  defp display(principal_id) do
    case Contacts.find(principal_id) do
      {:ok, %{display_name: name}} when is_binary(name) -> name
      _ -> principal_id
    end
  end

  defp one_line(text) do
    text |> String.replace(~r/\s+/, " ") |> String.slice(0, 100)
  end
end
