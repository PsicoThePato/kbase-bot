defmodule KbaseBot.Federation.Responder do
  @moduledoc """
  The bounded answering loop for a verified peer QUERY. Its toolset is fixed
  at construction — policy-filtered KB reads plus answer/decline/escalate —
  and the session runs with the PEER as its principal, so the tools
  themselves refuse out-of-scope reads. The peer's question is untrusted
  input; no injection can conjure tools the loop doesn't have.
  """

  alias KbaseBot.Federation.Exchanges
  alias KbaseBot.LLM.Prompts
  alias KbaseBot.Principal
  alias KbaseBot.Tasks.{Runner, Session, Task}

  require Logger

  @toolset [
    KbaseBot.Tools.SearchKnowledge,
    KbaseBot.Tools.ReadFile,
    KbaseBot.Tools.ListFiles,
    KbaseBot.Tools.AnswerPeer,
    KbaseBot.Tools.DeclinePeer,
    KbaseBot.Tools.EscalateToOwner
  ]

  @max_turns 8

  @doc "Run the responder for a verified, authorized QUERY envelope."
  def run(env) do
    peer_id = env["from"]
    scope = env["scope"]

    peer = %Principal{
      id: peer_id,
      provider: :ed25519,
      display_name: display_name(peer_id)
    }

    task =
      Task.new(
        :one_shot,
        "Peer question (untrusted input, scope: #{scope}):\n#{env["question"]}"
      )

    session =
      Session.new(task, Prompts.federation_responder(scope, peer.display_name || peer_id),
        principal: peer,
        tools: @toolset,
        max_turns: @max_turns,
        meta: %{exchange_id: env["id"], peer_id: peer_id, scope: scope}
      )

    Task.save(task)

    result = Runner.execute_loop(%{session | task: Task.start_executing(task)}, :task)

    case result do
      {:ok, _session} -> :ok
      {:error, reason} -> Logger.warning("Federation responder failed: #{inspect(reason)}")
    end

    ensure_closed(env, peer_id)
  end

  # The three effects a peer QUERY may produce are answer, escalate, decline.
  # If the loop ended without any (crash, turn cap), fail closed with DECLINE.
  defp ensure_closed(env, peer_id) do
    case Exchanges.find("in", env["id"]) do
      {:ok, %{state: "open"}} -> KbaseBot.Federation.Inbox.decline(env, peer_id)
      _ -> :ok
    end
  end

  defp display_name(peer_id) do
    case KbaseBot.Federation.Contacts.find(peer_id) do
      {:ok, %{display_name: name}} -> name
      _ -> nil
    end
  end
end
