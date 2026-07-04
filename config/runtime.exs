import Config

if config_env() != :test do
  console? = System.get_env("CONSOLE_MODE", "false") == "true"

  config :kbase_bot,
    console_mode: console?,
    anthropic_api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
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
    exa_api_key: System.get_env("EXA_API_KEY")

  if console? do
    config :kbase_bot, telegram_bot_token: nil, telegram_chat_id: 0
  else
    config :kbase_bot,
      telegram_bot_token: System.fetch_env!("TELEGRAM_BOT_TOKEN"),
      telegram_chat_id: System.fetch_env!("TELEGRAM_CHAT_ID") |> String.to_integer()

    config :ex_gram, token: System.fetch_env!("TELEGRAM_BOT_TOKEN")
  end
end
