defmodule KbaseBot.Console do
  @moduledoc """
  Interactive stdin/stdout interface for demo mode (`CONSOLE_MODE=true`).

  Replaces Telegram entirely: lines you type flow into the same Ingress
  debounce buffer real messages would, and anything the bot would send to
  Telegram is printed here instead (`KbaseBot.Telegram` routes to `print/1`
  when console mode is on).
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def print(text) do
    IO.puts(IO.ANSI.format([:cyan, "\nbot> ", :reset, text]))
    :ok
  end

  @impl true
  def init(_) do
    Logger.configure(level: log_level())
    IO.puts(banner())
    reader = spawn_link(fn -> read_loop() end)
    {:ok, %{reader: reader}}
  end

  defp read_loop do
    case IO.gets("") do
      :eof ->
        System.stop(0)

      {:error, _} ->
        System.stop(1)

      line ->
        case String.trim(line) do
          "" -> :ok
          cmd when cmd in ["/quit", "/exit"] -> System.stop(0)
          text -> KbaseBot.Ingress.push(text)
        end

        read_loop()
    end
  end

  defp log_level do
    case System.get_env("LOG_LEVEL") do
      nil -> :warning
      level -> String.to_existing_atom(level)
    end
  end

  defp banner do
    """
    ── KbaseBot console demo ──────────────────────────────────────────
    Chatting with the sample knowledge base (a duck's personal notes).
    Messages are debounced for 2s, and KB questions run as background
    tasks — give it a few seconds to answer.

    Try:  what's my flight training today?
          what am I absolutely not allowed to eat?
          how is operation second pond going?
          remind me to practice V-formation every day at 7am

    /quit to exit.
    ───────────────────────────────────────────────────────────────────
    """
  end
end
