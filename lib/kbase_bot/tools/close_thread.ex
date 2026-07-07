defmodule KbaseBot.Tools.CloseThread do
  @moduledoc false
  @behaviour KbaseBot.Tool

  @impl true
  def name, do: "close_thread"

  @impl true
  def description do
    "End the current discussion thread (goal reached, dead end, or the conversation should stop)."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        reason: %{type: "string", description: "Short reason, shared with the peer"}
      }
    }
  end

  @impl true
  def layer, do: :federation

  @impl true
  def execute(input, context) do
    case KbaseBot.Federation.Threads.find(context[:thread_id] || "") do
      {:ok, thread} ->
        KbaseBot.Federation.Discussion.close_thread(thread, input["reason"] || "closed")
        {:ok, "Thread closed."}

      _ ->
        {:error, "no thread in context"}
    end
  end
end
