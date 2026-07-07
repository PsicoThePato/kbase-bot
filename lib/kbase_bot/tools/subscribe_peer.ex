defmodule KbaseBot.Tools.SubscribePeer do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Bindings, Envelope, Outbound, Subscriptions}

  @impl true
  def name, do: "subscribe_peer"

  @impl true
  def description do
    "Subscribe to a peer's scope: they push new items, our evaluator files the interesting ones into inbox/<topic>/. Requires them to have granted us subscribe on that scope."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{type: "string", description: "The contact's principal id"},
        scope: %{type: "string", description: "THEIR scope label (or pass topic instead)"},
        topic: %{
          type: "string",
          description: "YOUR topic — resolved via bindings, and used to file incoming items"
        }
      },
      required: ["principal_id"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"principal_id" => peer} = input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context),
         {:ok, scope} <- resolve_scope(input, peer),
         {:ok, envelope} <-
           Envelope.build("SUBSCRIBE", %{"to" => peer, "scope" => scope, "proof" => []}) do
      case Outbound.deliver(envelope, peer) do
        :ok ->
          topic = input["topic"] || scope
          Subscriptions.upsert("out", peer, scope, topic)
          {:ok, "Subscribed to #{peer}'s #{scope} (filed under inbox/#{topic}/)."}

        {:error, reason} ->
          {:error, "delivery failed: #{inspect(reason)}"}
      end
    else
      {:error, :no_identity} -> {:error, "no federation identity configured"}
      err -> err
    end
  end

  defp resolve_scope(%{"scope" => scope}, _peer) when is_binary(scope) and scope != "" do
    {:ok, scope}
  end

  defp resolve_scope(%{"topic" => topic}, peer) when is_binary(topic) and topic != "" do
    case Bindings.resolve(topic, peer) do
      [best | _] -> {:ok, best}
      [] -> {:error, "no binding for topic \"#{topic}\" at this peer — pass scope explicitly"}
    end
  end

  defp resolve_scope(_, _), do: {:error, "pass either scope or topic"}
end
