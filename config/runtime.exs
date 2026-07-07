import Config

if config_env() != :test do
  console? = System.get_env("CONSOLE_MODE", "false") == "true"
  # Demo mode (mix kbase_bot.demo): federation-only children, deterministic
  # LLM stub, no API keys or Telegram needed. Never set this in production.
  demo? = System.get_env("KBASE_DEMO", "false") == "true"

  if demo? do
    config :kbase_bot,
      demo_mode: true,
      llm_client: KbaseBot.LLM.DemoStub
  end

  config :kbase_bot,
    console_mode: console?,
    # SQLite location. Unset ⇒ <app dir>/priv/repo.db, which only works when
    # the app lives somewhere writable (dev checkout). Packaged deployments
    # (Nix store is read-only) must point this at their state directory.
    db_path: System.get_env("DB_PATH"),
    anthropic_api_key:
      if(demo?,
        do: System.get_env("ANTHROPIC_API_KEY", "demo-unused"),
        else: System.fetch_env!("ANTHROPIC_API_KEY")
      ),
    model: System.get_env("MODEL", "claude-sonnet-5"),
    repo_path: System.get_env("REPO_PATH", "./knowledge_base"),
    prompts_dir: System.get_env("PROMPTS_DIR"),
    timezone: System.get_env("TIMEZONE", "America/Sao_Paulo"),
    locale: System.get_env("LOCALE", "pt"),
    auto_commit: System.get_env("AUTO_COMMIT", "true") == "true",
    scheduler_poll_interval_ms:
      System.get_env("SCHEDULER_POLL_MS", "15000") |> String.to_integer(),
    daily_llm_call_budget: System.get_env("DAILY_LLM_CALL_BUDGET", "300") |> String.to_integer(),
    giphy_api_key: System.get_env("GIPHY_API_KEY"),
    qmd_path: System.get_env("QMD_PATH", "qmd"),
    qmd_enabled: System.get_env("QMD_ENABLED", "true") == "true",
    voyage_api_key: System.get_env("VOYAGE_API_KEY"),
    embedding_poll_interval_ms:
      System.get_env("EMBEDDING_POLL_MS", "60000") |> String.to_integer(),
    todoist_api_key: System.get_env("TODOIST_API_KEY"),
    exa_api_key: System.get_env("EXA_API_KEY"),
    federation_enabled: System.get_env("FEDERATION_ENABLED", "false") == "true",
    federation_key_path: System.get_env("FEDERATION_KEY_PATH"),
    federation_port: System.get_env("FEDERATION_PORT", "4040") |> String.to_integer(),
    federation_public_url: System.get_env("FEDERATION_PUBLIC_URL"),
    federation_display_name: System.get_env("FEDERATION_DISPLAY_NAME", "KbaseBot"),
    # Escape hatch for local multi-bot testing: skips the outbound SSRF guard
    # (private/loopback endpoint addresses). Never enable in production.
    federation_allow_private_endpoints:
      System.get_env("FEDERATION_ALLOW_PRIVATE_ENDPOINTS", "false") == "true",
    # Monthly cap on peer-triggered LLM loops, per principal (the inference fuse).
    federation_peer_monthly_loops:
      System.get_env("FEDERATION_PEER_MONTHLY_BUDGET", "100") |> String.to_integer(),
    # Store-and-forward retry tick and "peer unreachable" owner-alert threshold.
    federation_queue_tick_ms:
      System.get_env("FEDERATION_QUEUE_TICK_MS", "60000") |> String.to_integer(),
    federation_unreachable_alert_s:
      System.get_env("FEDERATION_UNREACHABLE_ALERT_DAYS", "3")
      |> String.to_integer()
      |> Kernel.*(86_400)

  # tzdata caches IANA releases in its own priv dir by default — read-only
  # when the app is packaged (Nix store). Point it somewhere writable.
  case System.get_env("TZDATA_DIR") do
    nil -> :ok
    dir -> config :tzdata, :data_dir, dir
  end

  if console? or demo? do
    config :kbase_bot, telegram_bot_token: nil, telegram_chat_id: 0
  else
    config :kbase_bot,
      telegram_bot_token: System.fetch_env!("TELEGRAM_BOT_TOKEN"),
      telegram_chat_id: System.fetch_env!("TELEGRAM_CHAT_ID") |> String.to_integer()

    config :ex_gram, token: System.fetch_env!("TELEGRAM_BOT_TOKEN")
  end
end
