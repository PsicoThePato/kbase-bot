defmodule KbaseBot.Tools.AnswerPeer do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Envelope, Exchanges, Outbound}
  alias KbaseBot.Identity.Keys

  @impl true
  def name, do: "answer_peer"

  @impl true
  def description do
    "Send your answer back to the peer agent that asked. Answer only from content you actually retrieved; keep it concise."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        answer: %{type: "string", description: "The answer to deliver"},
        confidence: %{
          type: "string",
          enum: ["high", "medium", "low"],
          description: "How confident you are given the retrieved content"
        }
      },
      required: ["answer"]
    }
  end

  @impl true
  def layer, do: :federation

  @impl true
  def execute(%{"answer" => answer} = input, context) do
    exchange_id = context[:exchange_id]
    peer_id = context[:peer_id]

    with true <- is_binary(exchange_id) and is_binary(peer_id),
         {:ok, own_id} <- Keys.own_principal_id(),
         {:ok, envelope} <-
           Envelope.build("ANSWER", %{
             "in_reply_to" => exchange_id,
             "to" => peer_id,
             "answer" => answer,
             "confidence" => input["confidence"] || "medium",
             "provenance" => [own_id]
           }),
         :ok <- Outbound.deliver(envelope, peer_id) do
      Exchanges.set_state("in", exchange_id, "answered")
      {:ok, "Answer delivered to peer."}
    else
      _ -> {:error, "could not deliver answer"}
    end
  end
end
