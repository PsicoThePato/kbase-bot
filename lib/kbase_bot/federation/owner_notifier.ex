defmodule KbaseBot.Federation.OwnerNotifier do
  @moduledoc """
  The one channel from the federation subsystem to the human owner's chat.

  Two hard rules keep the Manager loop injection-proof:

  * Nothing federation-originated is ever pushed into the Manager loop. The
    Manager only *initiates* federation actions through its tools and reads
    their synchronous return values; it never receives federation events as
    conversation. So there is no `manager_note` here — by design.
  * Only two kinds of text reach the owner through `notify_owner/1`: our own
    metadata (ids we generated, verified fingerprints, scopes we chose,
    control-signal codes), and the output of confined subagents that already
    ran at a peer's clearance. Raw, unmediated peer content never travels
    this way — substantive peer replies are processed by a confined
    interlocutor/discussant that reports through its own `notify_user`.
  """

  @doc "Deliver an owner-facing notification to the owner's chat."
  def notify_owner(text) do
    case Application.get_env(:kbase_bot, :telegram_chat_id) do
      nil -> :ok
      chat_id -> KbaseBot.Telegram.send_message(chat_id, text)
    end

    :ok
  end

  @doc """
  Make a peer-chosen identifier safe to show in an owner notification: a
  plain token passes through, anything else is redacted (a peer must not be
  able to smuggle newlines/markup into an owner-facing line).
  """
  def safe_token(id) when is_binary(id) do
    if Regex.match?(~r/^[A-Za-z0-9_-]{1,64}$/, id), do: id, else: "(unprintable id)"
  end

  def safe_token(_), do: "(unprintable id)"
end
