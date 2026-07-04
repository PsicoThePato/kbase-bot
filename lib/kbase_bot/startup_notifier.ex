defmodule KbaseBot.StartupNotifier do
  @moduledoc """
  Sends a one-shot Telegram message when the bot boots, so every deploy —
  and every unexpected restart — is visible on the phone. Silence after a
  deploy means something is wrong.
  """

  require Logger

  def notify do
    chat_id = Application.fetch_env!(:kbase_bot, :telegram_chat_id)

    KbaseBot.Telegram.send_message(
      chat_id,
      "[System] Bot online — build #{KbaseBot.BuildInfo.git_sha()}"
    )
  rescue
    e -> Logger.warning("Startup notification failed: #{inspect(e)}")
  end
end
