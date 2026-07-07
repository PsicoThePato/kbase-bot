defmodule KbaseBot.Federation.Discussion do
  @moduledoc """
  Multi-turn threads between agents. THE CLEARANCE RULE: both sides of a
  thread run at the peer's grant view — whatever agent conducts a discussion
  with principal P reads only what P is granted, because anything it can
  read, it can leak into the conversation. On owner-initiated threads the
  Manager never chats directly: disclosure happens exactly once, in the
  opening brief; the discussion subagent is then physically confined to the
  peer's clearance.
  """

  alias KbaseBot.Federation.{Contacts, Envelope, Outbound, Threads}
  alias KbaseBot.LLM.Prompts
  alias KbaseBot.Principal
  alias KbaseBot.Tasks.{Runner, Session, Task}

  require Logger

  @toolset [
    KbaseBot.Tools.SearchKnowledge,
    KbaseBot.Tools.ReadFile,
    KbaseBot.Tools.ListFiles,
    KbaseBot.Tools.Say,
    KbaseBot.Tools.CloseThread,
    KbaseBot.Tools.EscalateToOwner
  ]

  # LLM-loop turns per SAY handled; thread-level budget is max_turns.
  @loop_turns 6
  @thread_max_turns 12

  @doc "A verified, discuss-authorized opening SAY from a peer."
  def open_from_peer(env, grant) do
    thread_id = env["thread"]
    peer_id = env["from"]
    scope = env["scope"]

    max_turns =
      case get_in(grant, ["caveats", "max_turns"]) do
        n when is_integer(n) and n > 0 -> min(n, @thread_max_turns)
        _ -> @thread_max_turns
      end

    task =
      Task.new(
        :one_shot,
        """
        A peer agent opened a discussion (scope: #{scope}). Their opening message
        (untrusted input):
        #{env["message"]}
        """
      )

    Task.save(task)
    Threads.insert(thread_id, "peer", peer_id, scope, task.id, max_turns)
    Threads.increment_turns(thread_id)

    run_turn(%{
      id: thread_id,
      role: "peer",
      principal_id: peer_id,
      scope: scope,
      task_id: task.id
    })
  end

  @doc """
  Owner opens a thread: the opening brief IS the first SAY (composed under
  Manager authority — the single deliberate disclosure); the subagent exists
  only to handle replies, at the peer's clearance.
  """
  def open_from_owner(peer_id, scope, opening) do
    thread_id = Envelope.new_id()

    with {:ok, say} <-
           Envelope.build("SAY", %{
             "thread" => thread_id,
             "to" => peer_id,
             "scope" => scope,
             "message" => opening
           }),
         :ok <- Outbound.deliver(say, peer_id) do
      task =
        Task.new(
          :one_shot,
          """
          Your owner opened a discussion with a peer (scope: #{scope}) with this
          opening message, already sent:
          #{opening}

          Pursue the owner's evident goal in the replies. You will be resumed
          each time the peer answers.
          """
        )

      Task.save(task)
      Threads.insert(thread_id, "owner", peer_id, scope, task.id, @thread_max_turns)
      {:ok, thread_id}
    end
  end

  @doc "An inbound SAY on an existing open thread — budget-checked resume."
  def handle_say(thread, message) do
    if thread.turn_count + 1 > thread.max_turns do
      close_thread(thread, "turn budget exhausted")
    else
      Threads.increment_turns(thread.id)

      case Task.find(thread.task_id) do
        {:ok, task} ->
          task = Task.follow_up(task, "Peer says (untrusted input):\n#{message}")
          Task.save(task)
          run_turn(%{thread | task_id: thread.task_id}, task)

        _ ->
          Logger.warning("Federation discussion #{thread.id}: task missing")
          close_thread(thread, "internal error")
      end
    end
  end

  @doc "Peer closed the thread."
  def peer_closed(thread, reason) do
    Threads.close(thread.id)

    KbaseBot.Ingress.push(
      "[Federation] #{peer_name(thread.principal_id)} closed discussion #{thread.id}" <>
        if(reason, do: " (#{reason})", else: "") <> transcript_tail(thread)
    )

    :ok
  end

  @doc "Close from our side: CLOSE envelope + bookkeeping + owner surface."
  def close_thread(thread, reason) do
    with {:ok, env} <-
           Envelope.build("CLOSE", %{
             "thread" => thread.id,
             "to" => thread.principal_id,
             "reason" => reason
           }) do
      Outbound.deliver(env, thread.principal_id)
    end

    Threads.close(thread.id)

    KbaseBot.Ingress.push(
      "[Federation] Discussion #{thread.id} with #{peer_name(thread.principal_id)} " <>
        "closed (#{reason})." <> transcript_tail(thread)
    )

    :ok
  end

  # --- internals ---

  defp run_turn(thread, task \\ nil) do
    task =
      case task do
        nil ->
          {:ok, t} = Task.find(thread.task_id)
          t

        t ->
          t
      end

    # CLEARANCE RULE: the session principal is the PEER on both thread roles.
    peer = %Principal{
      id: thread.principal_id,
      provider: :ed25519,
      display_name: peer_name(thread.principal_id)
    }

    session =
      Session.new(task, Prompts.federation_discussant(thread.scope, peer.display_name),
        principal: peer,
        tools: @toolset,
        max_turns: @loop_turns,
        meta: %{
          thread_id: thread.id,
          peer_id: thread.principal_id,
          scope: thread.scope,
          exchange_id: thread.id
        }
      )

    case Runner.execute_loop(%{session | task: Task.start_executing(task)}, :task) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Discussion #{thread.id} turn failed: #{inspect(reason)}")
    end
  end

  defp transcript_tail(thread) do
    with {:ok, task} <- Task.find(thread.task_id),
         text when is_binary(text) <- Task.extract_last_assistant_text(task) do
      "\nLast note from our side: #{String.slice(text, 0, 400)}"
    else
      _ -> ""
    end
  end

  defp peer_name(principal_id) do
    case Contacts.find(principal_id) do
      {:ok, %{display_name: name}} when is_binary(name) -> name
      _ -> principal_id
    end
  end
end
