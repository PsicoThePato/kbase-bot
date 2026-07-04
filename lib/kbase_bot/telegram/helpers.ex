defmodule KbaseBot.Telegram do
  @moduledoc """
  Telegram helper functions for sending messages.
  """

  require Logger

  @max_message_length 4096

  def send_message(chat_id, text) when byte_size(text) <= @max_message_length do
    ExGram.send_message(chat_id, text, parse_mode: "Markdown")
  rescue
    _ -> ExGram.send_message(chat_id, text)
  end

  def send_message(chat_id, text) do
    text
    |> split_message()
    |> Enum.each(fn chunk ->
      ExGram.send_message(chat_id, chunk)
      Process.sleep(100)
    end)
  end

  defp split_message(text) do
    text
    |> String.split("\n\n")
    |> Enum.chunk_while(
      "",
      fn paragraph, acc ->
        candidate = if acc == "", do: paragraph, else: acc <> "\n\n" <> paragraph

        if byte_size(candidate) <= @max_message_length do
          {:cont, candidate}
        else
          if acc == "" do
            # Single paragraph too long — force split
            {:cont, String.slice(paragraph, 0, @max_message_length), ""}
          else
            {:cont, acc, paragraph}
          end
        end
      end,
      fn
        "" -> {:cont, ""}
        acc -> {:cont, acc, ""}
      end
    )
    |> Enum.reject(&(&1 == ""))
  end
end
