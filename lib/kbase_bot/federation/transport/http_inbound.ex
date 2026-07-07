defmodule KbaseBot.Federation.Transport.HTTPInbound do
  @moduledoc """
  Inbound HTTP adapter: accepts signed envelopes at POST /federation/inbox
  and normalizes them into the Inbox. Always 204 — authorization outcomes
  travel as reply envelopes, never as HTTP status (deny-by-default extends to
  the transport layer).

  A pre-auth throttle (per source IP + global) runs before body parsing: the
  Inbox's per-principal rate limit only exists after signature verification,
  so without this, garbage floods would pile unbounded casts into the single
  Inbox process. Envelopes are small; bodies are capped at 64 KiB.
  """

  use Plug.Router

  # Owned by the Inbox GenServer (it starts before Bandit).
  @rate_table :federation_http_rate
  @window_ms 60_000
  @per_ip_limit 60
  @global_limit 600

  plug(:throttle)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: 65_536)
  plug(:dispatch)

  post "/federation/inbox" do
    if is_map(conn.body_params) and map_size(conn.body_params) > 0 do
      KbaseBot.Federation.Inbox.push(conn.body_params)
    end

    send_resp(conn, 204, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp throttle(conn, _opts) do
    if allow?(conn.remote_ip) do
      conn
    else
      conn |> send_resp(429, "") |> halt()
    end
  end

  @doc false
  # Approximate windowed counters; races between request processes only make
  # the limit slightly elastic. Fails open if the table is missing — the
  # Inbox owns it, and with the Inbox down the cast goes nowhere anyway.
  def allow?(remote_ip) do
    case :ets.whereis(@rate_table) do
      :undefined -> true
      _ -> bump(:global) <= @global_limit and bump(remote_ip) <= @per_ip_limit
    end
  end

  defp bump(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@rate_table, key) do
      [{^key, window_start, _count}] when now - window_start < @window_ms ->
        :ets.update_counter(@rate_table, key, {3, 1})

      _ ->
        :ets.insert(@rate_table, {key, now, 1})
        1
    end
  end
end
