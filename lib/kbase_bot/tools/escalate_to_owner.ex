defmodule KbaseBot.Tools.EscalateToOwner do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Envelope, Exchanges, Outbound}

  @impl true
  def name, do: "escalate_to_owner"

  @impl true
  def description do
    "Surface the peer's question to your owner when you can't or shouldn't answer autonomously (low confidence, or the answer seems to need a human call). The peer is told a human was asked."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        question: %{
          type: "string",
          description: "The question to surface to the owner, with any useful context"
        }
      },
      required: ["question"]
    }
  end

  @impl true
  def layer, do: :federation

  @impl true
  def execute(%{"question" => question}, context) do
    exchange_id = context[:exchange_id]
    peer_id = context[:peer_id]

    with true <- is_binary(exchange_id) and is_binary(peer_id),
         {:ok, envelope} <-
           Envelope.build("ESCALATED", %{"in_reply_to" => exchange_id, "to" => peer_id}),
         :ok <- Outbound.deliver(envelope, peer_id) do
      Exchanges.set_state("in", exchange_id, "escalated")

      peer_name =
        case KbaseBot.Federation.Contacts.find(peer_id) do
          {:ok, %{display_name: name}} when is_binary(name) -> name
          _ -> peer_id
        end

      KbaseBot.Ingress.push(
        "[Federation] #{peer_name}'s agent asks (exchange #{exchange_id}):\n#{question}\n" <>
          "Reply with the answer_escalation tool (exchange_id: #{exchange_id}) or leave it."
      )

      {:ok, "Escalated to owner; the peer was told a human will answer later."}
    else
      _ -> {:error, "could not escalate"}
    end
  end
end
