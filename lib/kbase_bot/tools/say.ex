defmodule KbaseBot.Tools.Say do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Envelope, Outbound}

  @impl true
  def name, do: "say"

  @impl true
  def description do
    "Send one message in the current discussion thread, then STOP and wait for the peer's reply. Call it at most once per turn."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        message: %{type: "string", description: "Your message, composed for external ears"}
      },
      required: ["message"]
    }
  end

  @impl true
  def layer, do: :federation

  @impl true
  def execute(%{"message" => message}, context) do
    thread_id = context[:thread_id]
    peer_id = context[:peer_id]

    with true <- is_binary(thread_id) and is_binary(peer_id),
         {:ok, envelope} <-
           Envelope.build("SAY", %{"thread" => thread_id, "to" => peer_id, "message" => message}),
         :ok <- Outbound.deliver(envelope, peer_id) do
      {:ok, "Sent. Now stop — you will be resumed when the peer replies."}
    else
      _ -> {:error, "could not deliver message"}
    end
  end
end
