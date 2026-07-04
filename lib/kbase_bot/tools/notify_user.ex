defmodule KbaseBot.Tools.NotifyUser do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "notify_user"

  @impl true
  def description do
    "Send an interim notification to the user while a task is still running. Use for progress updates on long-running tasks."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        message: %{type: "string", description: "The notification message"}
      },
      required: ["message"]
    }
  end

  @impl true
  def layer, do: :task

  @impl true
  def execute(%{"message" => message}, _context) do
    chat_id = Application.fetch_env!(:kbase_bot, :telegram_chat_id)
    KbaseBot.Telegram.send_message(chat_id, message)
    {:ok, "Notification sent."}
  end
end
