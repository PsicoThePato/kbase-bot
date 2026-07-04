defmodule KbaseBot.Tools.JournalEntry do
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "journal_entry"

  @impl true
  def description do
    "Append a journal entry to today's daily file. Use when the user sends personal notes, diary entries, or thoughts they want to save."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        text: %{type: "string", description: "The journal entry text to save"}
      },
      required: ["text"]
    }
  end

  @impl true
  def layer, do: :manager

  @impl true
  def execute(%{"text" => text}, _context) do
    case KbaseBot.Journal.Writer.append_entry(text) do
      {:ok, filename, time_str} ->
        KbaseBot.Context.Server.refresh()
        {:ok, "Saved to Journal/#{filename} at #{time_str} BRT"}

      {:error, reason} ->
        {:error, "Failed to save journal entry: #{inspect(reason)}"}
    end
  end
end
