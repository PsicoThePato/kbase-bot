defmodule KbaseBot.Federation.Outbound do
  @moduledoc """
  Deliver an envelope to a peer: walk their card's endpoint list top-down and
  use the first transport we speak. No shared transport ⇒ surfaced, not
  silently dropped.
  """

  alias KbaseBot.Federation.{Contacts, Transport}

  require Logger

  @spec deliver(map(), String.t()) :: :ok | {:error, term()}
  def deliver(envelope, peer_id) do
    with {:ok, %{card: card}} <- Contacts.find(peer_id) do
      endpoints =
        (card["endpoints"] || [])
        |> Enum.sort_by(fn ep -> ep["priority"] || 99 end)

      attempt(envelope, endpoints, peer_id)
    else
      _ -> {:error, :unknown_contact}
    end
  end

  defp attempt(_envelope, [], peer_id) do
    Logger.warning("Federation: no usable transport for #{peer_id} — contact unreachable")
    {:error, :unreachable}
  end

  defp attempt(envelope, [endpoint | rest], peer_id) do
    case Transport.adapter(endpoint["transport"]) do
      nil ->
        attempt(envelope, rest, peer_id)

      adapter ->
        case adapter.deliver(envelope, endpoint) do
          :ok -> :ok
          {:error, _reason} -> attempt(envelope, rest, peer_id)
        end
    end
  end
end
