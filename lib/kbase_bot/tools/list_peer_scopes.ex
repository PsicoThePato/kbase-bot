defmodule KbaseBot.Tools.ListPeerScopes do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Envelope, Exchanges, Outbound}

  @impl true
  def name, do: "list_peer_scopes"

  @impl true
  def description do
    "Ask a peer which of their scopes are visible to us (grant-gated). Async: the list arrives later as a [Federation] message."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{type: "string", description: "The contact's principal id"}
      },
      required: ["principal_id"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"principal_id" => peer}, context) do
    with :ok <- KbaseBot.Tool.require_owner(context),
         {:ok, envelope} <- Envelope.build("LIST-SCOPES", %{"to" => peer}) do
      Exchanges.open("out", envelope["id"], "LIST-SCOPES", peer, nil, nil)

      case Outbound.deliver(envelope, peer) do
        :ok -> {:ok, "Scope listing requested (exchange #{envelope["id"]})."}
        {:error, :unknown_contact} -> {:error, "unknown contact #{peer}"}
        {:error, reason} -> {:error, "delivery failed: #{inspect(reason)}"}
      end
    else
      {:error, :no_identity} ->
        {:error, "no federation identity configured (FEDERATION_KEY_PATH)"}

      err ->
        err
    end
  end
end
