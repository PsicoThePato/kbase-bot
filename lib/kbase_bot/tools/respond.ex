defmodule KbaseBot.Tools.Respond do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "respond"

  @impl true
  def description,
    do: "Send a text response to the user via Telegram. Use this to communicate with the user."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        text: %{type: "string", description: "The message text to send to the user"}
      },
      required: ["text"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"text" => text}, context) do
    chat_id = Map.get(context, :chat_id)

    if chat_id do
      KbaseBot.Telegram.send_message(chat_id, text)
      {:ok, "Message sent."}
    else
      {:error, "No chat_id in context"}
    end
  end
end
