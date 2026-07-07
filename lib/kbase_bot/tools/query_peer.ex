defmodule KbaseBot.Tools.QueryPeer do
  @moduledoc false
  @behaviour KbaseBot.Tool

  alias KbaseBot.Federation.{Disclosures, Envelope, Exchanges, Outbound}

  @impl true
  def name, do: "query_peer"

  @impl true
  def description do
    "Ask a federated peer's agent a question in one of THEIR scopes (see list_peer_scopes). Async: when the answer arrives, a confined subagent limited to that peer's permissions processes it and reports to the owner directly — you never see the answer yourself. If the owner wants the answer actively worked on or negotiated, use discuss_peer with a mission instead. Compose the question for external ears — it leaves this bot."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        principal_id: %{type: "string", description: "The contact's principal id"},
        scope: %{
          type: "string",
          description: "The RECIPIENT's scope label to ask under (or pass topic instead)"
        },
        topic: %{
          type: "string",
          description:
            "YOUR topic label — resolved to the peer's scope via bindings (see list_bindings)"
        },
        question: %{type: "string", description: "The question, composed for external ears"}
      },
      required: ["principal_id", "question"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"principal_id" => peer, "question" => question} = input, context) do
    with :ok <- KbaseBot.Tool.require_owner(context),
         {:ok, scope} <- resolve_scope(input, peer),
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
          # The question itself leaves this bot — that's a disclosure too.
          Disclosures.log(peer, scope, "query", envelope["id"], question)
          {:ok, "Query sent (exchange #{envelope["id"]}). The answer arrives asynchronously."}

        {:error, :unknown_contact} ->
          {:error, "unknown contact #{peer} — add them first"}
      end
    else
      {:error, :no_identity} ->
        {:error, "no federation identity configured (FEDERATION_KEY_PATH)"}

      err ->
        err
    end
  end

  # Topic → peer scope through the binding table (confirmed > confidence);
  # an explicit scope always wins.
  defp resolve_scope(%{"scope" => scope}, _peer) when is_binary(scope) and scope != "" do
    {:ok, scope}
  end

  defp resolve_scope(%{"topic" => topic}, peer) when is_binary(topic) and topic != "" do
    case KbaseBot.Federation.Bindings.resolve(topic, peer) do
      [best | _] ->
        {:ok, best}

      [] ->
        {:error,
         "no binding for topic \"#{topic}\" at this peer — run list_peer_scopes first, " <>
           "bind_topic manually, or pass their scope explicitly"}
    end
  end

  defp resolve_scope(_, _), do: {:error, "pass either scope or topic"}
end
