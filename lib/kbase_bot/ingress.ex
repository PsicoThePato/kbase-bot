defmodule KbaseBot.Ingress do
  @moduledoc """
  2-second debounce buffer for incoming Telegram messages.
  Batches rapid messages and flushes them to the Manager as one unit.
  """
  use GenServer

  require Logger

  @grace_period_ms 2_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def push(text, meta \\ %{}) do
    GenServer.cast(__MODULE__, {:push, text, meta})
  end

  # --- Server ---

  @impl true
  def init(_) do
    {:ok, %{buffer: [], timer_ref: nil}}
  end

  @impl true
  def handle_cast({:push, text, meta}, state) do
    principal = Map.get(meta, :principal) || KbaseBot.Principal.owner()
    # Newest first; reversed at flush
    state = %{state | buffer: [{principal, text} | state.buffer]}

    state =
      if state.timer_ref == nil do
        ref = Process.send_after(self(), :flush, @grace_period_ms)
        %{state | timer_ref: ref}
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    if state.buffer != [] do
      Logger.info("Ingress: flushing #{length(state.buffer)} message(s) to Manager")
      KbaseBot.Manager.process(Enum.reverse(state.buffer))
    end

    {:noreply, %{buffer: [], timer_ref: nil}}
  end
end
