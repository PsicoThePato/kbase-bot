defmodule KbaseBot.Federation.Inbox do
  @moduledoc """
  The single normalization point for inbound federation traffic. Every
  envelope, whatever pipe it rode: signature verified against the stored
  contact card → principal resolved → rate limited → routed by kind under the
  initiator rule. Unverifiable or uncorrelated envelopes are dropped.

  Peer-authored bytes NEVER enter the Manager loop — not pushed, not pulled.
  Every interaction with a peer is handled by a subagent confined to THAT
  peer's clearance (inbound QUERY → Responder; inbound SAY → Discussant;
  our own query_peer's ANSWER → Interlocutor), whose toolset is fixed at
  spawn. Those subagents reach the owner only through their own notify_user;
  short control signals reach the owner as our-own-metadata via
  `OwnerNotifier.notify_owner/1`. The Manager only ever initiates federation
  actions through tools and reads their return values — it receives no
  federation events as conversation.
  """

  use GenServer

  alias KbaseBot.Federation.{
    Canonical,
    Card,
    Contacts,
    Envelope,
    Exchanges,
    Grants,
    Outbound,
    OwnerNotifier,
    PeerBudget,
    Responder,
    Verifier
  }

  alias KbaseBot.Identity.Keys

  require Logger

  @rate_table :federation_rate
  # Pre-auth throttle table for the HTTP transport (owned here so it exists
  # before Bandit accepts traffic; the plug fails open if the Inbox is down —
  # its casts go nowhere then anyway).
  @http_rate_table :federation_http_rate
  # One in-flight discussion loop per thread (see route("SAY", ...)).
  @busy_table :federation_busy_threads
  # Per-principal inbound envelopes per hour.
  @rate_limit 30
  @window_ms 3_600_000
  # Replay protection: signed `ts` must be within [-7d, +5min] of now, and an
  # accepted (peer, id) pair is single-use. 7 days still allows the design's
  # "an ANSWER hours later is the same exchange" late delivery.
  @max_age_s 7 * 86_400
  @max_skew_s 300
  @seen_retention_s 14 * 86_400
  @prune_interval_ms 6 * 3_600_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Normalize an inbound envelope (any transport). Fire-and-forget."
  def push(envelope) do
    GenServer.cast(__MODULE__, {:envelope, envelope})
  end

  @impl true
  def init(_) do
    :ets.new(@rate_table, [:named_table, :set, :public])
    :ets.new(@http_rate_table, [:named_table, :set, :public])
    :ets.new(@busy_table, [:named_table, :set, :public])
    Process.send_after(self(), :prune_seen, @prune_interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:envelope, envelope}, state) do
    process(envelope)
    {:noreply, state}
  end

  @impl true
  def handle_info(:prune_seen, state) do
    cutoff =
      DateTime.utc_now() |> DateTime.add(-@seen_retention_s, :second) |> DateTime.to_iso8601()

    KbaseBot.Repo.Store.execute("DELETE FROM seen_envelopes WHERE seen_at < ?1", [cutoff])
    Process.send_after(self(), :prune_seen, @prune_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  # Public for the integration test's synchronous assertions.
  def process(envelope) do
    with true <- is_map(envelope),
         from when is_binary(from) <- envelope["from"],
         {:ok, pub} <- Contacts.pubkey_for(from),
         true <- Canonical.verified?(envelope, pub),
         :ok <- rate_check(from),
         :ok <- freshness_check(envelope),
         :ok <- replay_check(from, envelope["id"]) do
      route(envelope["kind"], from, envelope)
    else
      _ ->
        # One legitimate class of envelope arrives from a principal we don't
        # know yet: a CARD-UPDATE announcing a key rotation of a contact we
        # DO know. Everything else from a stranger drops.
        maybe_rotation(envelope)
    end
  end

  # A rotation CARD-UPDATE is signed by the NEW key (the old one may be
  # retired), so it can't pass the normal stored-contact verification. It
  # earns processing on its own strict terms: envelope signed by the card's
  # key, card+proof internally valid (Card.verify), and — the check only we
  # can make — the proof's old key equal to the pubkey we already store
  # (Contacts.apply_rotation). All the usual pre-auth gates still apply.
  defp maybe_rotation(
         %{"kind" => "CARD-UPDATE", "from" => from, "card" => %{"rotation" => _} = card} = env
       )
       when is_binary(from) do
    with %{"principal" => ^from} <- card,
         {:ok, pub} <- Card.pubkey(card),
         true <- Keys.fingerprint(pub) == from,
         true <- Canonical.verified?(env, pub),
         :ok <- rate_check(from),
         :ok <- freshness_check(env),
         :ok <- replay_check(from, env["id"]),
         {:ok, old_id} when is_binary(old_id) <- Contacts.apply_rotation(card) do
      OwnerNotifier.notify_owner(
        "[Federation] Contact key rotation: #{OwnerNotifier.safe_token(old_id)} is now " <>
          "#{OwnerNotifier.safe_token(from)}. Grants, bindings, subscriptions and history " <>
          "were migrated."
      )

      :ok
    else
      {:ok, :already_applied} ->
        :ok

      _ ->
        Logger.debug("Federation inbox: dropped unverifiable envelope")
        :drop
    end
  end

  defp maybe_rotation(_envelope) do
    Logger.debug("Federation inbox: dropped unverifiable envelope")
    :drop
  end

  # The signed issued-at bounds how long a captured envelope stays usable and
  # lets the seen-id table be pruned instead of growing forever.
  defp freshness_check(%{"ts" => ts}) when is_integer(ts) do
    now = System.os_time(:second)

    if now - ts <= @max_age_s and ts - now <= @max_skew_s do
      :ok
    else
      Logger.debug("Federation inbox: stale/future envelope dropped")
      :stale
    end
  end

  defp freshness_check(_), do: :no_timestamp

  # First use wins, forever: a replayed (or id-reusing) envelope can never
  # rerun a responder, flip an exchange's state, or resurrect a subscription.
  defp replay_check(from, id) when is_binary(id) and id != "" do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case KbaseBot.Repo.Store.execute(
           "INSERT INTO seen_envelopes (peer, envelope_id, seen_at) VALUES (?1, ?2, ?3)",
           [from, id, now]
         ) do
      :ok ->
        :ok

      {:error, _} ->
        Logger.debug("Federation inbox: replayed envelope #{id} from #{from} dropped")
        :replay
    end
  end

  defp replay_check(_, _), do: :no_id

  # --- Routing (the initiator rule) ---

  # Peer-initiated: handling may produce exactly a bounded responder task,
  # an escalation to the owner, or a DECLINE. Nothing else, ever.
  defp route("QUERY", from, env) do
    scope = env["scope"]
    proof = env["proof"] || []

    Exchanges.open("in", env["id"], "QUERY", from, scope, env["question"])

    with {:ok, _grant} <- Verifier.authorize(from, scope, "query", proof),
         :ok <- budget_check(from, env) do
      Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
        Responder.run(env)
      end)

      :ok
    else
      {:error, :declined} -> decline(env, from)
      :budget_declined -> :ok
    end
  end

  defp route("LIST-SCOPES", from, env) do
    descriptions = KbaseBot.Policy.Scopes.descriptions()

    scopes =
      Grants.granted_scopes(from)
      |> Enum.map(fn name ->
        case descriptions[name] do
          nil -> %{"name" => name}
          desc -> %{"name" => name, "description" => desc}
        end
      end)

    with {:ok, reply} <-
           Envelope.build("SCOPES", %{
             "in_reply_to" => env["id"],
             "to" => from,
             "scopes" => scopes
           }) do
      Outbound.deliver(reply, from)
    end

    :ok
  end

  # Peer subscribes to one of my scopes: authorized like any capability
  # exercise; silence on success (the feed items are the confirmation).
  defp route("SUBSCRIBE", from, env) do
    case Verifier.authorize(from, env["scope"], "subscribe", env["proof"] || []) do
      {:ok, _grant} ->
        KbaseBot.Federation.Subscriptions.upsert("in", from, env["scope"], nil)
        :ok

      {:error, :declined} ->
        decline(env, from)
    end
  end

  defp route("UNSUBSCRIBE", from, env) do
    KbaseBot.Federation.Subscriptions.set_state("in", from, env["scope"], "cancelled")
    :ok
  end

  # Initiator rule: a PUBLISH is ingested only against a subscription I
  # initiated. Anything else is an unsolicited push — dropped.
  defp route("PUBLISH", from, env) do
    with {:ok, subscription} <-
           KbaseBot.Federation.Subscriptions.find_active("out", from, env["scope"]),
         :ok <- budget_check(from, env) do
      Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
        KbaseBot.Federation.Evaluator.run(env, subscription)
      end)

      :ok
    else
      {:error, :not_found} ->
        Logger.debug("Federation inbox: unsolicited PUBLISH from #{from} dropped")
        :drop

      :budget_declined ->
        :ok
    end
  end

  # Discussions: the opening SAY is authorized like any capability exercise;
  # later SAYs resume the pinned thread (budget-checked). Mid-thread scope
  # switches are declined; SAYs on foreign/closed threads drop.
  #
  # Turn handling is serialized per thread: exactly one loop may be in flight
  # (the busy set), and the turn budget is claimed atomically in SQL — two
  # rapid SAYs can neither run concurrent loops over the same task history
  # nor both pass a stale budget check.
  defp route("SAY", from, env) do
    alias KbaseBot.Federation.{Discussion, Threads}

    case Threads.find(env["thread"] || "") do
      {:error, :not_found} ->
        with {:ok, grant} <-
               Verifier.authorize(from, env["scope"], "discuss", env["proof"] || []),
             :ok <- budget_check(from, env) do
          thread_id = env["thread"]

          Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
            with_thread_lock(thread_id, fn ->
              # Re-check under the lock: a duplicate opening SAY that raced
              # the first one's insert must not reset the thread.
              case Threads.find(thread_id || "") do
                {:error, :not_found} ->
                  Discussion.open_from_peer(env, grant)

                _ ->
                  Logger.debug("Federation inbox: duplicate thread open from #{from} dropped")
              end
            end)
          end)

          :ok
        else
          {:error, :declined} -> decline(env, from)
          :budget_declined -> :ok
        end

      {:ok, %{principal_id: ^from, state: "open"} = thread} ->
        cond do
          env["scope"] not in [nil, thread.scope] ->
            decline(env, from)

          budget_check(from, env) != :ok ->
            # Turn not claimed, thread stays open — the peer can resume when
            # their budget resets next month.
            :ok

          true ->
            message = env["message"]

            Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
              with_thread_lock(thread.id, fn ->
                case Threads.claim_turn(thread.id) do
                  :ok -> Discussion.handle_say(thread, message)
                  :exhausted -> Discussion.close_thread(thread, "turn budget exhausted")
                  :unavailable -> :ok
                end
              end)
            end)

            :ok
        end

      _ ->
        Logger.debug("Federation inbox: SAY on foreign/closed thread from #{from} dropped")
        :drop
    end
  end

  defp route("CLOSE", from, env) do
    alias KbaseBot.Federation.{Discussion, Threads}

    case Threads.find(env["thread"] || "") do
      {:ok, %{principal_id: ^from, state: "open"} = thread} ->
        Discussion.peer_closed(thread, env["reason"])

      _ ->
        :drop
    end
  end

  defp route("CARD-UPDATE", from, env) do
    case env["card"] do
      %{"principal" => ^from} = card ->
        Contacts.add_card(card)
        :ok

      _ ->
        :drop
    end
  end

  # Replies to owner-initiated exchanges: data flowing into my standing
  # request. Uncorrelated replies drop.
  defp route(kind, from, env) when kind in ["ANSWER", "DECLINE", "ESCALATED", "SCOPES"] do
    case Exchanges.find("out", env["in_reply_to"] || "") do
      {:ok, %{peer: ^from, state: state} = exchange} when state in ["open", "escalated"] ->
        handle_reply(kind, exchange, env)

      _ ->
        Logger.debug("Federation inbox: uncorrelated #{kind} from #{from} dropped")
        :drop
    end
  end

  # Open enum: unknown kinds are declined, not crashed.
  defp route(_unknown_kind, from, env), do: decline(env, from)

  # Every reply to an owner-initiated exchange is mediated at the peer's
  # clearance — peer bytes enter only a confined subagent, never the owner's
  # Telegram raw and never the Manager loop. The Manager gets, at most, a
  # metadata note built from our own fields (ids we generated, verified
  # fingerprints, the scope we chose) so it can correlate.

  # A peer's ANSWER is handed to a confined interlocutor (peer clearance;
  # reads filtered, only write is the quarantine inbox, only owner channel is
  # notify_user). It composes the owner-facing report — the peer's prose is
  # never delivered unmediated.
  defp handle_reply("ANSWER", exchange, env) do
    Exchanges.set_state("out", exchange.id, "answered")

    Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
      KbaseBot.Federation.Interlocutor.handle_answer(exchange, env)
    end)

    :ok
  end

  # Control signals (no substantive peer content): our own metadata to the
  # owner. `reason` is a short peer-supplied code, delivered to the human
  # owner only — never into the Manager loop.
  defp handle_reply("DECLINE", exchange, env) do
    Exchanges.set_state("out", exchange.id, "declined")

    OwnerNotifier.notify_owner(
      "[Federation] #{peer_name(exchange.peer)} declined exchange #{exchange.id} " <>
        "(#{env["reason"] || "no_answer"})."
    )

    :ok
  end

  defp handle_reply("ESCALATED", exchange, _env) do
    Exchanges.set_state("out", exchange.id, "escalated")

    OwnerNotifier.notify_owner(
      "[Federation] #{peer_name(exchange.peer)} escalated exchange #{exchange.id} " <>
        "to their human — an answer may arrive later."
    )

    :ok
  end

  # A peer's advertised scope names/descriptions are peer content — they go
  # only to the confined binder (a toolless classifier that validates its
  # output against our own vocabulary). The owner learns from the binder's
  # mediated binding proposals, not a raw dump of the list.
  defp handle_reply("SCOPES", exchange, env) do
    Exchanges.set_state("out", exchange.id, "answered")

    scopes = env["scopes"] || []

    OwnerNotifier.notify_owner(
      "[Federation] #{peer_name(exchange.peer)} advertised #{length(scopes)} scope(s) " <>
        "visible to us; binding proposals may follow."
    )

    Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
      KbaseBot.Federation.Binder.propose(exchange.peer, scopes)
    end)

    :ok
  end

  @doc false
  def decline(env, from, reason \\ "no_answer") do
    Exchanges.set_state("in", env["id"] || "", "declined")

    with {:ok, reply} <-
           Envelope.build("DECLINE", %{
             "in_reply_to" => env["id"],
             "to" => from,
             "reason" => reason
           }) do
      Outbound.deliver(reply, from)
    end

    :ok
  end

  # The monthly inference fuse: every peer-triggered LLM loop counts against
  # the sender. Past the cap the peer gets a DECLINE that SAYS so — unlike
  # the no-grant DECLINE (deliberately indistinguishable from "no such
  # scope"), `rate_limited` leaks nothing about the KB and tells a
  # well-behaved peer to stop burning both sides' envelopes.
  defp budget_check(from, env) do
    case PeerBudget.check_and_increment(from) do
      :ok ->
        :ok

      {:error, :budget_exhausted} ->
        decline(env, from, "rate_limited")
        :budget_declined
    end
  end

  # One in-flight discussion loop per thread. Runs `fun` if the lock is won
  # within `timeout`; a queued SAY waits for the running loop instead of
  # racing it, and is dropped (logged) only if the wait times out.
  @doc false
  def with_thread_lock(thread_id, fun, timeout \\ 30_000) do
    if acquire_lock(thread_id, timeout) do
      try do
        fun.()
      after
        :ets.delete(@busy_table, thread_id)
      end
    else
      Logger.warning("Federation inbox: thread #{inspect(thread_id)} busy — SAY dropped")
      :drop
    end
  end

  defp acquire_lock(thread_id, timeout) do
    cond do
      :ets.insert_new(@busy_table, {thread_id}) ->
        true

      timeout <= 0 ->
        false

      true ->
        Process.sleep(50)
        acquire_lock(thread_id, timeout - 50)
    end
  end

  defp peer_name(principal_id) do
    case Contacts.find(principal_id) do
      {:ok, %{display_name: name}} when is_binary(name) -> "#{name} (#{principal_id})"
      _ -> principal_id
    end
  end

  defp rate_check(principal_id) do
    now = System.monotonic_time(:millisecond)

    count =
      case :ets.lookup(@rate_table, principal_id) do
        [{^principal_id, window_start, count}] when now - window_start < @window_ms ->
          :ets.insert(@rate_table, {principal_id, window_start, count + 1})
          count + 1

        _ ->
          :ets.insert(@rate_table, {principal_id, now, 1})
          1
      end

    if count <= @rate_limit do
      :ok
    else
      Logger.warning("Federation: rate limit exceeded for #{principal_id}")
      :rate_limited
    end
  end
end
