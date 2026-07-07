defmodule KbaseBot.Federation.Transport.HTTPS do
  @moduledoc """
  Outbound HTTP(S) delivery: POST the envelope as JSON to the endpoint.

  The address comes from the peer's self-signed card, i.e. it is
  attacker-controlled for any added-but-ungranted contact — so it is vetted
  before every request (scheme, and no private/loopback/link-local/metadata
  destinations) and redirects are never followed. DNS answers are checked at
  send time; a TOCTOU rebinding window remains, which is acceptable for the
  data this can carry (envelopes we composed). Set
  `federation_allow_private_endpoints: true` for local multi-bot testing.
  """

  @behaviour KbaseBot.Federation.Transport

  import Bitwise

  require Logger

  @impl true
  def deliver(envelope, %{"address" => address}) do
    with :ok <- ensure_safe(address) do
      case Req.post(address,
             json: envelope,
             retry: false,
             redirect: false,
             receive_timeout: 10_000
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          Logger.warning("Federation HTTPS delivery to #{address} got #{status}")
          {:error, {:http_status, status}}

        {:error, reason} ->
          Logger.warning("Federation HTTPS delivery to #{address} failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, reason} = error ->
        Logger.warning(
          "Federation HTTPS delivery refused: unsafe endpoint #{address} (#{inspect(reason)})"
        )

        error
    end
  end

  def deliver(_envelope, _endpoint), do: {:error, :invalid_endpoint}

  @doc "Vet a peer-supplied delivery address. Public for tests."
  @spec ensure_safe(term()) :: :ok | {:error, term()}
  def ensure_safe(address) when is_binary(address) do
    if Application.get_env(:kbase_bot, :federation_allow_private_endpoints, false) do
      :ok
    else
      uri = URI.parse(address)

      cond do
        uri.scheme not in ["http", "https"] -> {:error, :bad_scheme}
        uri.host in [nil, ""] -> {:error, :bad_host}
        true -> check_host(uri.host)
      end
    end
  end

  def ensure_safe(_), do: {:error, :bad_address}

  defp check_host(host) do
    chars = String.to_charlist(host)

    addrs =
      case :inet.parse_address(chars) do
        {:ok, addr} -> [addr]
        _ -> resolve(chars)
      end

    cond do
      addrs == [] -> {:error, :unresolvable}
      Enum.any?(addrs, &private_address?/1) -> {:error, :private_address}
      true -> :ok
    end
  end

  defp resolve(chars) do
    for family <- [:inet, :inet6],
        {:ok, addrs} <- [:inet.getaddrs(chars, family)],
        addr <- addrs,
        do: addr
  end

  # Loopback, RFC1918, link-local (incl. the 169.254.169.254 metadata
  # service), CGNAT, unspecified, multicast/reserved/broadcast, ULA, and
  # v4-mapped v6 forms of all of the above.
  defp private_address?({127, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({172, b, _, _}) when b in 16..31, do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({100, b, _, _}) when b in 64..127, do: true
  defp private_address?({0, _, _, _}), do: true
  defp private_address?({a, _, _, _}) when a >= 224, do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: private_address?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})

  defp private_address?({a, _, _, _, _, _, _, _}) when band(a, 0xFE00) == 0xFC00, do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when band(a, 0xFFC0) == 0xFE80, do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when band(a, 0xFF00) == 0xFF00, do: true
  defp private_address?(_), do: false
end
