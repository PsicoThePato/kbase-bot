defmodule KbaseBot.Federation.Transport do
  @moduledoc """
  Transport is an adapter, not part of the protocol: envelopes are signed, so
  any pipe that moves bytes is valid. Adapters implement `deliver/2`; inbound
  adapters all normalize into `Federation.Inbox`.
  """

  @callback deliver(envelope :: map(), endpoint :: map()) :: :ok | {:error, term()}

  @adapters %{
    "https" => KbaseBot.Federation.Transport.HTTPS,
    "http" => KbaseBot.Federation.Transport.HTTPS,
    "loopback" => KbaseBot.Federation.Transport.Loopback
  }

  @doc "Adapter module for a transport name, or nil when we don't speak it."
  def adapter(transport), do: @adapters[transport]
end
