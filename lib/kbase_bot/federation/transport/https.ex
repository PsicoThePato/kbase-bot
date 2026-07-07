defmodule KbaseBot.Federation.Transport.HTTPS do
  @moduledoc "Outbound HTTP(S) delivery: POST the envelope as JSON to the endpoint."

  @behaviour KbaseBot.Federation.Transport

  require Logger

  @impl true
  def deliver(envelope, %{"address" => address}) do
    case Req.post(address, json: envelope, retry: false, receive_timeout: 10_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("Federation HTTPS delivery to #{address} got #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.warning("Federation HTTPS delivery to #{address} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def deliver(_envelope, _endpoint), do: {:error, :invalid_endpoint}
end
