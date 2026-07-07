defmodule KbaseBot.Federation.Transport.Loopback do
  @moduledoc """
  In-VM delivery — the test harness. Delivers to `:loopback_receiver`
  (a pid registered by tests, which receives `{:federation_envelope, env}`)
  or, when none is set, back into this node's own Inbox.
  """

  @behaviour KbaseBot.Federation.Transport

  @impl true
  def deliver(envelope, _endpoint) do
    case Application.get_env(:kbase_bot, :loopback_receiver) do
      pid when is_pid(pid) ->
        send(pid, {:federation_envelope, envelope})
        :ok

      _ ->
        KbaseBot.Federation.Inbox.push(envelope)
        :ok
    end
  end
end
