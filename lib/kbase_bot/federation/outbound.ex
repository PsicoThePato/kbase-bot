defmodule KbaseBot.Federation.Outbound do
  @moduledoc """
  Deliver an envelope to a peer: walk their card's endpoint list top-down and
  use the first transport we speak. A failed first attempt is not a loss —
  the envelope is parked in the durable OutboundQueue and retried with
  backoff (the protocol is async; correlation is by id, not by timing), so
  `:ok` means "delivered or durably queued". Only an unknown contact is a
  hard error: with no card there is nowhere to ever deliver.
  """

  alias KbaseBot.Federation.{Contacts, OutboundQueue}

  require Logger

  @spec deliver(map(), String.t()) :: :ok | {:error, :unknown_contact}
  def deliver(envelope, peer_id) do
    case Contacts.find(peer_id) do
      {:ok, _contact} ->
        case OutboundQueue.attempt(envelope, peer_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.info(
              "Federation: delivery to #{peer_id} failed (#{inspect(reason)}) — queued for retry"
            )

            OutboundQueue.enqueue(envelope, peer_id, reason)
            :ok
        end

      _ ->
        {:error, :unknown_contact}
    end
  end
end
