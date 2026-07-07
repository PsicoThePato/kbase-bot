defmodule KbaseBot.Tools.ShowTrustSignals do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Contacts, PeerBudget, TrustSignals}

  @impl true
  def name, do: "show_trust_signals"

  @impl true
  def description do
    "Show accumulated per-(peer, topic) promote/discard verdicts on pushed content — the raw signal a future trust algorithm will train on — plus each peer's inference-budget usage this month."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{type: "string", description: "Limit to one peer (omit for all)"}
      }
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      signals =
        case TrustSignals.stats(input["principal_id"]) do
          [] ->
            "No trust signals yet — they accumulate as you promote/discard inbox items."

          stats ->
            Enum.map_join(stats, "\n", fn s ->
              total = s.promoted + s.discarded

              "- #{display(s.principal_id)} · #{s.topic}: " <>
                "#{s.promoted}/#{total} promoted"
            end)
        end

      usage =
        case PeerBudget.usage() do
          [] ->
            ""

          rows ->
            "\n\nInference loops this month:\n" <>
              Enum.map_join(rows, "\n", fn u -> "- #{display(u.peer)}: #{u.loops}" end)
        end

      {:ok, signals <> usage}
    end
  end

  defp display(principal_id) do
    case Contacts.find(principal_id) do
      {:ok, %{display_name: name}} when is_binary(name) -> "#{name} (#{principal_id})"
      _ -> principal_id
    end
  end
end
