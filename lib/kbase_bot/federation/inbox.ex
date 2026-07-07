defmodule KbaseBot.Federation.Inbox do
  @moduledoc """
  The single normalization point for inbound federation traffic. Every
  envelope, whatever pipe it rode: signature verified against the stored
  contact card → principal resolved → rate limited → routed by kind under the
  initiator rule. Unverifiable or uncorrelated envelopes are dropped.

  Inbound messages NEVER enter the Manager loop — peer queries spawn a
  constrained responder; owner-bound notifications travel as plain text
  through Ingress (data, not capability).
  """

  use GenServer

  alias KbaseBot.Federation.{
    Canonical,
    Contacts,
    Envelope,
    Exchanges,
    Grants,
    Outbound,
    Responder,
    Verifier
  }

  require Logger

  @rate_table :federation_rate
  # Per-principal inbound envelopes per hour.
  @rate_limit 30
  @window_ms 3_600_000

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
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:envelope, envelope}, state) do
    process(envelope)
    {:noreply, state}
  end

  @doc false
  # Public for the integration test's synchronous assertions.
  def process(envelope) do
    with true <- is_map(envelope),
         from when is_binary(from) <- envelope["from"],
         {:ok, pub} <- Contacts.pubkey_for(from),
         true <- Canonical.verified?(envelope, pub),
         :ok <- rate_check(from) do
      route(envelope["kind"], from, envelope)
    else
      _ ->
        Logger.debug("Federation inbox: dropped unverifiable envelope")
        :drop
    end
  end

  # --- Routing (the initiator rule) ---

  # Peer-initiated: handling may produce exactly a bounded responder task,
  # an escalation to the owner, or a DECLINE. Nothing else, ever.
  defp route("QUERY", from, env) do
    scope = env["scope"]
    proof = env["proof"] || []

    Exchanges.open("in", env["id"], "QUERY", from, scope, env["question"])

    case Verifier.authorize(from, scope, "query", proof) do
      {:ok, _grant} ->
        Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
          Responder.run(env)
        end)

        :ok

      {:error, :declined} ->
        decline(env, from)
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

  defp handle_reply("ANSWER", exchange, env) do
    Exchanges.set_state("out", exchange.id, "answered")

    surface(
      "[Federation] Answer from #{peer_name(exchange.peer)} " <>
        "(exchange #{exchange.id}, scope #{exchange.scope}):\n#{env["answer"]}\n" <>
        "(Their question context: #{exchange.question})"
    )

    :ok
  end

  defp handle_reply("DECLINE", exchange, env) do
    Exchanges.set_state("out", exchange.id, "declined")

    surface(
      "[Federation] #{peer_name(exchange.peer)} declined exchange #{exchange.id} " <>
        "(#{env["reason"] || "no_answer"})."
    )

    :ok
  end

  defp handle_reply("ESCALATED", exchange, _env) do
    Exchanges.set_state("out", exchange.id, "escalated")

    surface(
      "[Federation] #{peer_name(exchange.peer)} escalated exchange #{exchange.id} " <>
        "to their human — an answer may arrive later."
    )

    :ok
  end

  defp handle_reply("SCOPES", exchange, env) do
    Exchanges.set_state("out", exchange.id, "answered")

    names =
      (env["scopes"] || [])
      |> Enum.map(fn
        %{"name" => name} = s ->
          case s["description"] do
            nil -> name
            desc -> "#{name} — #{desc}"
          end

        other ->
          to_string(other)
      end)

    surface(
      "[Federation] Scopes visible to us at #{peer_name(exchange.peer)}: " <>
        (names
         |> Enum.join("; ")
         |> case do
           "" -> "(none)"
           list -> list
         end)
    )

    # The translation layer's LLM-judgment step: propose topic bindings from
    # the advertised names/descriptions (auto-bind or ask the owner).
    Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
      KbaseBot.Federation.Binder.propose(exchange.peer, env["scopes"] || [])
    end)

    :ok
  end

  @doc false
  def decline(env, from) do
    Exchanges.set_state("in", env["id"] || "", "declined")

    with {:ok, reply} <-
           Envelope.build("DECLINE", %{
             "in_reply_to" => env["id"],
             "to" => from,
             "reason" => "no_answer"
           }) do
      Outbound.deliver(reply, from)
    end

    :ok
  end

  defp surface(text) do
    KbaseBot.Ingress.push(text)
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
