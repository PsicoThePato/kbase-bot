defmodule KbaseBot.Tools.DeclinePeer do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "decline_peer"

  @impl true
  def description do
    "Decline the peer's question. Use when the granted scopes don't contain an answer. The peer cannot distinguish 'no grant' from 'no content' — that is deliberate."
  end

  @impl true
  def parameters, do: %{type: "object", properties: %{}}

  @impl true
  def layer, do: :federation

  @impl true
  def execute(_input, context) do
    exchange_id = context[:exchange_id]
    peer_id = context[:peer_id]

    if is_binary(exchange_id) and is_binary(peer_id) do
      KbaseBot.Federation.Inbox.decline(%{"id" => exchange_id}, peer_id)
      {:ok, "Declined."}
    else
      {:error, "no exchange in context"}
    end
  end
end
