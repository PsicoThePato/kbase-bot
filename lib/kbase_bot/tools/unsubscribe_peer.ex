defmodule KbaseBot.Tools.UnsubscribePeer do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Envelope, Outbound, Subscriptions}

  @impl true
  def name, do: "unsubscribe_peer"

  @impl true
  def description, do: "End our subscription to a peer's scope."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{type: "string"},
        scope: %{
          type: "string",
          description: "THEIR scope label (as shown by list_subscriptions)"
        }
      },
      required: ["principal_id", "scope"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"principal_id" => peer, "scope" => scope}, context) do
    with :ok <- KbaseBot.Tool.require_owner(context),
         {:ok, envelope} <- Envelope.build("UNSUBSCRIBE", %{"to" => peer, "scope" => scope}) do
      Outbound.deliver(envelope, peer)
      Subscriptions.set_state("out", peer, scope, "cancelled")
      {:ok, "Unsubscribed from #{peer}'s #{scope}."}
    else
      {:error, :no_identity} -> {:error, "no federation identity configured"}
      err -> err
    end
  end
end
