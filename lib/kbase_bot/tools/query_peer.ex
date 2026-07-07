defmodule KbaseBot.Tools.QueryPeer do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Envelope, Exchanges, Outbound}

  @impl true
  def name, do: "query_peer"

  @impl true
  def description do
    "Ask a federated peer's agent a question in one of THEIR scopes (see list_peer_scopes). Async: the answer arrives later as a [Federation] message. Compose the question for external ears — it leaves this bot."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{type: "string", description: "The contact's principal id"},
        scope: %{type: "string", description: "The RECIPIENT's scope label to ask under"},
        question: %{type: "string", description: "The question, composed for external ears"}
      },
      required: ["principal_id", "scope", "question"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"principal_id" => peer, "scope" => scope, "question" => question}, context) do
    with :ok <- KbaseBot.Tool.require_owner(context),
         {:ok, envelope} <-
           Envelope.build("QUERY", %{
             "to" => peer,
             "scope" => scope,
             "question" => question,
             "ttl_hops" => 0,
             "proof" => [],
             "provenance" => []
           }) do
      Exchanges.open("out", envelope["id"], "QUERY", peer, scope, question)

      case Outbound.deliver(envelope, peer) do
        :ok ->
          {:ok, "Query sent (exchange #{envelope["id"]}). The answer arrives asynchronously."}

        {:error, :unknown_contact} ->
          {:error, "unknown contact #{peer} — add them first"}

        {:error, :unreachable} ->
          Exchanges.set_state("out", envelope["id"], "closed")
          {:error, "contact is unreachable (no shared transport)"}

        {:error, reason} ->
          {:error, "delivery failed: #{inspect(reason)}"}
      end
    else
      {:error, :no_identity} ->
        {:error, "no federation identity configured (FEDERATION_KEY_PATH)"}

      err ->
        err
    end
  end
end
