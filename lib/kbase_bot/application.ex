defmodule KbaseBot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      cond do
        not Application.get_env(:kbase_bot, :start_children?, true) ->
          []

        # Demo mode (mix kbase_bot.demo): store + federation only — no
        # Manager, no interfaces, no scheduler, no LLM API.
        Application.get_env(:kbase_bot, :demo_mode, false) ->
          [
            KbaseBot.Repo.Store,
            KbaseBot.Context.Server,
            materialize_child(),
            {Elixir.Task.Supervisor, name: KbaseBot.TaskSupervisor}
          ] ++ federation_children()

        true ->
          [
            KbaseBot.Repo.Store,
            KbaseBot.Context.Server,
            materialize_child()
          ] ++
            embedder_children() ++
            [
              KbaseBot.Ingress,
              KbaseBot.Manager,
              {Elixir.Task.Supervisor, name: KbaseBot.TaskSupervisor}
            ] ++
            interface_children() ++
            federation_children() ++
            [KbaseBot.Scheduler.Scheduler]
      end

    opts = [strategy: :one_for_one, name: KbaseBot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # One-shot, :temporary: rebuilds bot-written KB files from the kb_writes log,
  # then syncs the search index to whatever is on disk. Runs after
  # Store + Context.Server, before anything reads or searches the KB.
  defp materialize_child do
    %{
      id: :kb_materialize,
      start:
        {Elixir.Task, :start_link,
         [
           fn ->
             KbaseBot.KB.Writer.materialize!()
             KbaseBot.KB.Chunker.reindex_all()
           end
         ]},
      restart: :temporary
    }
  end

  defp embedder_children do
    if Application.get_env(:kbase_bot, :voyage_api_key) in [nil, ""] do
      []
    else
      [KbaseBot.Memory.Embedder]
    end
  end

  defp federation_children do
    if Application.get_env(:kbase_bot, :federation_enabled, false) do
      [
        KbaseBot.Federation.Inbox,
        KbaseBot.Federation.OutboundQueue,
        {Bandit,
         plug: KbaseBot.Federation.Transport.HTTPInbound,
         port: Application.get_env(:kbase_bot, :federation_port, 4040),
         scheme: :http}
      ]
    else
      []
    end
  end

  defp interface_children do
    if Application.get_env(:kbase_bot, :console_mode, false) do
      [KbaseBot.Console]
    else
      [
        ExGram,
        {KbaseBot.Telegram.Bot, [method: :polling, token: ExGram.Config.get(:ex_gram, :token)]},
        # One-shot deploy/restart notification (Task children are :temporary,
        # so a failed send never restarts or takes down the tree)
        {Elixir.Task, &KbaseBot.StartupNotifier.notify/0}
      ]
    end
  end
end
