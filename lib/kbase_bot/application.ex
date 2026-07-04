defmodule KbaseBot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:kbase_bot, :start_children?, true) do
        [
          KbaseBot.Repo.Store,
          KbaseBot.Context.Server,
          KbaseBot.Memory.Embedder,
          KbaseBot.Ingress,
          KbaseBot.Manager,
          {Elixir.Task.Supervisor, name: KbaseBot.TaskSupervisor},
          ExGram,
          {KbaseBot.Telegram.Bot, [method: :polling, token: ExGram.Config.get(:ex_gram, :token)]},
          KbaseBot.Scheduler.Scheduler,
          # One-shot deploy/restart notification (Task children are :temporary,
          # so a failed send never restarts or takes down the tree)
          {Elixir.Task, &KbaseBot.StartupNotifier.notify/0}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: KbaseBot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
