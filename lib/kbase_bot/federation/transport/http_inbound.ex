defmodule KbaseBot.Federation.Transport.HTTPInbound do
  @moduledoc """
  Inbound HTTP adapter: accepts signed envelopes at POST /federation/inbox
  and normalizes them into the Inbox. Always 204 — authorization outcomes
  travel as reply envelopes, never as HTTP status (deny-by-default extends to
  the transport layer).
  """

  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
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
end
