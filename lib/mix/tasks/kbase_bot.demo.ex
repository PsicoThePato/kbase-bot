defmodule Mix.Tasks.KbaseBot.Demo do
  @shortdoc "Two-instance federation demo over real localhost HTTP"

  @moduledoc """
  Boots TWO federation instances with fresh identities — "Alice" inside this
  VM, "Bob" as a separate OS process — talking real HTTP through Bandit on
  localhost, and walks the protocol end to end:

    1. contact-card exchange
    2. scope advertisement (LIST-SCOPES → SCOPES)
    3. QUERY → policy-filtered responder → ANSWER → confined interlocutor
    4. an ungranted QUERY declined (deny by default)
    5. key rotation broadcast + re-query under the new identity
    6. store-and-forward: peer killed, envelope queued, peer restarted, delivered

  No API keys, Telegram, or network access needed: demo mode boots only the
  store + federation children and swaps the LLM for a deterministic stub
  (`KbaseBot.LLM.DemoStub`). This is the rehearsal for a real two-VPS deploy —
  the integration tests cover the logic in one VM; this covers Bandit, real
  transport, and two separate stores.

      mix kbase_bot.demo            # run, clean up tmp dirs
      mix kbase_bot.demo --keep     # leave tmp dirs behind for inspection
  """

  use Mix.Task

  @alice_port 4051
  @bob_port 4052

  @impl true
  def run(args) do
    keep? = "--keep" in args
    root = Path.join(System.tmp_dir!(), "kbase_demo_#{System.unique_integer([:positive])}")
    seed_dirs(root)

    # Env must be in place before app.start evaluates runtime.exs.
    System.put_env(alice_env(root))
    Mix.Task.run("app.start")
    Logger.configure(level: :warning)
    Application.put_env(:kbase_bot, :message_sink, self())

    bob = %{port: nil, os_pid: nil}

    try do
      generate_identities(root)
      publish_alice_card(root)

      bob = start_bob(root)
      run_acts(root, bob)
      info("\nAll acts passed. This is what the two-VPS deploy will do.")
    after
      kill_bob()
      unless keep?, do: File.rm_rf!(root)
      if keep?, do: info("Kept demo dirs at #{root}")
    end

    _ = bob
    :ok
  end

  # --- acts ---

  defp run_acts(root, bob) do
    alias KbaseBot.Federation.Rotation
    alias KbaseBot.Principal

    owner = %{principal: Principal.owner()}

    # Act 1 — contact cards
    act("1/6 contact-card exchange")
    bob_card = Path.join(root, "bob_card.json") |> File.read!() |> Jason.decode!()
    {:ok, bob_id} = KbaseBot.Federation.Contacts.add_card(bob_card, "demo peer")
    info("  Alice knows Bob: #{bob_id}")

    # Act 2 — scope advertisement
    act("2/6 scope advertisement (LIST-SCOPES)")
    {:ok, _} = KbaseBot.Tools.ListPeerScopes.execute(%{"principal_id" => bob_id}, owner)
    text = await_owner_msg("advertised", 10_000)
    info("  owner notification: #{text}")

    # Act 3 — granted QUERY, answered by a policy-filtered responder
    act("3/6 QUERY → ANSWER (granted scope)")
    ask_and_await_answer!(bob_id, owner)

    # Act 4 — ungranted QUERY is declined
    act("4/6 QUERY on an ungranted scope → DECLINE")

    {:ok, _} =
      KbaseBot.Tools.QueryPeer.execute(
        %{"principal_id" => bob_id, "scope" => "medical", "question" => "anything?"},
        owner
      )

    text = await_owner_msg("declined", 10_000)
    info("  owner notification: #{text}")

    # Act 5 — key rotation, then a query under the NEW identity
    act("5/6 key rotation broadcast, re-query as the new identity")
    {:ok, old_id} = KbaseBot.Identity.Keys.own_principal_id()
    {:ok, %{new_id: new_id, notified: 1}} = Rotation.rotate_own()
    info("  Alice rotated: #{old_id} → #{new_id}")
    # Future card shares (and Bob's restart in act 6) must use the new card.
    publish_alice_card(root)
    ask_and_await_answer!(bob_id, owner)
    info("  Bob migrated the grant to the new identity — query still answered")

    # Act 6 — store-and-forward across a peer outage
    act("6/6 store-and-forward: Bob dies, envelope queues, Bob returns")
    kill_bob()
    info("  Bob killed (pid #{bob.os_pid})")

    {:ok, message} =
      KbaseBot.Tools.QueryPeer.execute(
        %{"principal_id" => bob_id, "scope" => "movies", "question" => "still there?"},
        owner
      )

    exchange_id = parse_exchange_id(message)
    {:ok, queue_report} = KbaseBot.Tools.ListPendingDeliveries.execute(%{}, owner)
    info("  delivery queue: #{queue_report}")

    unless queue_report =~ "queued", do: fail("expected a queued envelope, got none")

    _bob2 = start_bob(root)
    # The retry is due in 60s; the demo fast-forwards the backoff.
    KbaseBot.Repo.Store.execute(
      "UPDATE outbound_queue SET next_attempt_at = '2000-01-01T00:00:00Z' WHERE state = 'queued'",
      []
    )

    KbaseBot.Federation.OutboundQueue.deliver_due()
    text = await_owner_msg("Peer replied", 15_000)
    info("  owner notification: #{text}")
    await_exchange_state!(exchange_id, "answered")
    info("  queued QUERY delivered after restart and answered")
  end

  # QUERY may race Bob's async processing of a rotation CARD-UPDATE (a QUERY
  # from a not-yet-migrated identity is dropped, not queued) — retry with
  # fresh envelopes instead of asserting on the first.
  defp ask_and_await_answer!(bob_id, owner, attempts \\ 4)

  defp ask_and_await_answer!(_bob_id, _owner, 0), do: fail("no ANSWER after retries")

  defp ask_and_await_answer!(bob_id, owner, attempts) do
    {:ok, message} =
      KbaseBot.Tools.QueryPeer.execute(
        %{"principal_id" => bob_id, "scope" => "movies", "question" => "any good movies?"},
        owner
      )

    exchange_id = parse_exchange_id(message)

    case await_owner_msg("Peer replied", 5_000, :soft) do
      {:ok, text} ->
        info("  confined interlocutor reported: #{String.slice(text, 0, 120)}")
        await_exchange_state!(exchange_id, "answered")

      :timeout ->
        ask_and_await_answer!(bob_id, owner, attempts - 1)
    end
  end

  # --- bob process management ---

  defp start_bob(root) do
    env =
      root
      |> bob_env()
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("mix")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 8192},
          args: ["run", "--no-halt", "priv/demo/peer_boot.exs"],
          cd: File.cwd!(),
          env: env
        ]
      )

    bob = wait_for_ready(port, %{port: port, os_pid: nil}, System.monotonic_time(:millisecond))
    Process.put(:demo_bob, bob)
    info("  Bob up (os pid #{bob.os_pid}, port #{@bob_port})")
    bob
  end

  defp wait_for_ready(port, bob, started_at) do
    if System.monotonic_time(:millisecond) - started_at > 120_000 do
      fail("Bob did not become ready within 120s")
    end

    receive do
      {^port, {:data, {:eol, "PEER-PID " <> os_pid}}} ->
        wait_for_ready(port, %{bob | os_pid: String.trim(os_pid)}, started_at)

      {^port, {:data, {:eol, "PEER-READY"}}} ->
        bob

      {^port, {:data, {:eol, line}}} ->
        if line != "", do: info("  [bob] #{line}")
        wait_for_ready(port, bob, started_at)

      {^port, {:exit_status, status}} ->
        fail("Bob exited with status #{status} before becoming ready")
    after
      120_000 -> fail("Bob did not become ready within 120s")
    end
  end

  defp kill_bob do
    case Process.get(:demo_bob) do
      %{os_pid: os_pid, port: port} when is_binary(os_pid) ->
        System.cmd("kill", ["-9", os_pid], stderr_to_stdout: true)
        drain_port(port)
        Process.delete(:demo_bob)

      _ ->
        :ok
    end
  end

  defp drain_port(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> drain_port(port)
    after
      3_000 -> :ok
    end
  end

  # --- environment / fixtures ---

  defp seed_dirs(root) do
    alice_kb = Path.join(root, "alice_kb")
    bob_kb = Path.join(root, "bob_kb")
    File.mkdir_p!(Path.join(alice_kb, "movies"))
    File.mkdir_p!(Path.join(bob_kb, "movies"))

    # Bob is the answering side: one granted-scope file, one that must stay
    # invisible (unlabeled ⇒ private) even though the responder lists files.
    File.write!(Path.join(bob_kb, "movies/watched.md"), """
    ---
    scopes: [movies]
    ---
    Dune Part Two: 9/10. Blade Runner 2049: 10/10.
    """)

    File.write!(Path.join(bob_kb, "diary.md"), "# Unlabeled — must stay private\n")

    File.write!(Path.join(bob_kb, ".kbase-policy.yml"), """
    defaults:
      "**": {scopes: [private]}
    non_grantable: [medical]
    scope_descriptions:
      movies: "films watched and ratings"
    """)

    File.write!(Path.join(alice_kb, "notes.md"), "# Alice's notes\n")
  end

  defp alice_env(root) do
    %{
      "KBASE_DEMO" => "true",
      "FEDERATION_ENABLED" => "true",
      "FEDERATION_KEY_PATH" => Path.join(root, "alice_identity.json"),
      "FEDERATION_PORT" => Integer.to_string(@alice_port),
      "FEDERATION_PUBLIC_URL" => "http://localhost:#{@alice_port}",
      "FEDERATION_DISPLAY_NAME" => "Alice",
      "FEDERATION_ALLOW_PRIVATE_ENDPOINTS" => "true",
      "REPO_PATH" => Path.join(root, "alice_kb"),
      "DB_PATH" => Path.join(root, "alice.db"),
      "QMD_ENABLED" => "false"
    }
  end

  defp bob_env(root) do
    %{
      "MIX_ENV" => Atom.to_string(Mix.env()),
      "KBASE_DEMO" => "true",
      "FEDERATION_ENABLED" => "true",
      "FEDERATION_KEY_PATH" => Path.join(root, "bob_identity.json"),
      "FEDERATION_PORT" => Integer.to_string(@bob_port),
      "FEDERATION_PUBLIC_URL" => "http://localhost:#{@bob_port}",
      "FEDERATION_DISPLAY_NAME" => "Bob",
      "FEDERATION_ALLOW_PRIVATE_ENDPOINTS" => "true",
      "REPO_PATH" => Path.join(root, "bob_kb"),
      "DB_PATH" => Path.join(root, "bob.db"),
      "QMD_ENABLED" => "false",
      "ALICE_CARD_FILE" => Path.join(root, "alice_card.json"),
      "BOB_CARD_FILE" => Path.join(root, "bob_card.json")
    }
  end

  defp generate_identities(root) do
    {:ok, alice_id} =
      KbaseBot.Identity.Keys.generate_to(Path.join(root, "alice_identity.json"))

    {:ok, bob_id} = KbaseBot.Identity.Keys.generate_to(Path.join(root, "bob_identity.json"))
    info("Alice: #{alice_id}")
    info("Bob:   #{bob_id}")
  end

  # (Re)write Alice's current card where Bob's boot script picks it up —
  # after a rotation this must be the NEW card, or a restarted Bob would
  # re-add the retired identity as a stranger.
  defp publish_alice_card(root) do
    endpoints = [
      %{
        "transport" => "https",
        "address" => "http://localhost:#{@alice_port}/federation/inbox",
        "priority" => 1
      }
    ]

    {:ok, card} =
      KbaseBot.Federation.Card.build(
        "Alice",
        System.os_time(:second),
        endpoints,
        [],
        KbaseBot.Federation.Rotation.proof()
      )

    File.write!(Path.join(root, "alice_card.json"), Jason.encode!(card))
  end

  # --- assertion helpers ---

  defp await_owner_msg(substring, timeout, mode \\ :hard) do
    receive do
      {:telegram, _chat, text} ->
        if text =~ substring do
          if mode == :hard, do: text, else: {:ok, text}
        else
          await_owner_msg(substring, timeout, mode)
        end
    after
      timeout ->
        if mode == :hard do
          fail("timed out waiting for an owner message containing #{inspect(substring)}")
        else
          :timeout
        end
    end
  end

  defp await_exchange_state!(exchange_id, state, tries \\ 40) do
    case KbaseBot.Federation.Exchanges.find("out", exchange_id) do
      {:ok, %{state: ^state}} ->
        :ok

      _ when tries > 0 ->
        Process.sleep(100)
        await_exchange_state!(exchange_id, state, tries - 1)

      other ->
        fail("exchange #{exchange_id} never reached #{state} (#{inspect(other)})")
    end
  end

  defp parse_exchange_id(message) do
    case Regex.run(~r/exchange (\S+?)\)/, message) do
      [_, id] -> id
      _ -> fail("could not parse exchange id from: #{message}")
    end
  end

  defp act(title), do: info("\n== #{title}")
  defp info(text), do: Mix.shell().info(text)
  defp fail(reason), do: Mix.raise("Demo failed: #{reason}")
end
