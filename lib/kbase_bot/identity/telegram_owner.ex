defmodule KbaseBot.Identity.TelegramOwner do
  @moduledoc """
  Identity provider for the existing Telegram auth gate: "matches owner chat
  id" → owner principal. Federation providers (keypair-based) plug in beside
  this one.
  """

  alias KbaseBot.Principal

  @spec verify(map()) :: {:ok, Principal.t()} | {:error, :unauthorized}
  def verify(context) do
    owner_id = Application.get_env(:kbase_bot, :telegram_chat_id)
    user_id = context.update.message.from.id

    if user_id == owner_id do
      {:ok, Principal.owner()}
    else
      {:error, :unauthorized}
    end
  end
end
