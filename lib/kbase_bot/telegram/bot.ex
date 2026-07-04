defmodule KbaseBot.Telegram.Bot do
  @bot :kbase_bot

  use ExGram.Bot,
    name: @bot,
    setup_commands: true

  require Logger

  command("start", description: "Start the bot")
  command("ask", description: "Ask a question about the knowledge base")
  command("cancel", description: "Cancel the active task")
  command("clear", description: "Clear conversation history")
  command("briefing", description: "Get today's briefing now")
  command("refresh", description: "Refresh knowledge base context")

  middleware(ExGram.Middleware.IgnoreUsername)

  def bot, do: @bot

  def handle({:command, "start", _msg}, context) do
    if authorized?(context) do
      answer(context, "KbaseBot is running.")
    end
  end

  def handle({:command, "ask", %{text: text}}, context) do
    if authorized?(context) do
      if text && text != "" do
        KbaseBot.Ingress.push("/ask #{text}")
      else
        answer(context, "Usage: /ask <your question>")
      end
    end
  end

  def handle({:command, "cancel", _msg}, context) do
    if authorized?(context) do
      KbaseBot.Ingress.push("/cancel")
    end
  end

  def handle({:command, "clear", _msg}, context) do
    if authorized?(context) do
      KbaseBot.Ingress.push("/clear")
    end
  end

  def handle({:command, "briefing", _msg}, context) do
    if authorized?(context) do
      KbaseBot.Ingress.push("/briefing")
    end
  end

  def handle({:command, "refresh", _msg}, context) do
    if authorized?(context) do
      KbaseBot.Ingress.push("/refresh")
    end
  end

  def handle({:text, text, _msg}, context) do
    if authorized?(context) do
      KbaseBot.Ingress.push(text)
    end
  end

  def handle(_, _context), do: :ok

  defp authorized?(context) do
    owner_id = Application.get_env(:kbase_bot, :telegram_chat_id)
    user_id = context.update.message.from.id
    user_id == owner_id
  end
end
