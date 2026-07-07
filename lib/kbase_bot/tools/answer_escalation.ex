defmodule KbaseBot.Tools.AnswerEscalation do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Envelope, Exchanges, Outbound}
  alias KbaseBot.Identity.Keys

  @impl true
  def name, do: "answer_escalation"

  @impl true
  def description do
    "Deliver the owner's answer to a peer question that was escalated to them (see the [Federation] message for the exchange_id)."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        exchange_id: %{type: "string", description: "The escalated exchange id"},
        answer: %{type: "string", description: "The owner's answer, composed for external ears"}
      },
      required: ["exchange_id", "answer"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"exchange_id" => exchange_id, "answer" => answer}, context) do
    with :ok <- KbaseBot.Tool.require_owner(context) do
      case Exchanges.find("in", exchange_id) do
        {:ok, %{state: "escalated", peer: peer}} ->
          with {:ok, own_id} <- Keys.own_principal_id(),
               {:ok, envelope} <-
                 Envelope.build("ANSWER", %{
                   "in_reply_to" => exchange_id,
                   "to" => peer,
                   "answer" => answer,
                   "confidence" => "high",
                   "provenance" => [own_id]
                 }),
               :ok <- Outbound.deliver(envelope, peer) do
            Exchanges.set_state("in", exchange_id, "answered")
            {:ok, "Answer delivered to #{peer}."}
          else
            _ -> {:error, "could not deliver the answer"}
          end

        {:ok, %{state: state}} ->
          {:error, "exchange #{exchange_id} is #{state}, not escalated"}

        {:error, :not_found} ->
          {:error, "no inbound exchange #{exchange_id}"}
      end
    end
  end
end
