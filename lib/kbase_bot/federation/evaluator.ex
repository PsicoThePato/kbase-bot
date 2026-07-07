defmodule KbaseBot.Federation.Evaluator do
  @moduledoc """
  Constrained loop for pushed items (PUBLISH). Same ceiling discipline as the
  responder: the toolset is fixed at construction to a single write —
  appending to the quarantine inbox. It can never touch the main KB, no
  matter how good the item looks; promotion is an owner action.
  """

  alias KbaseBot.LLM.Prompts
  alias KbaseBot.Principal
  alias KbaseBot.Tasks.{Runner, Session, Task}

  require Logger

  @toolset [KbaseBot.Tools.InboxAppend]
  @max_turns 3

  @doc "Evaluate a PUBLISH envelope against an active out-subscription."
  def run(env, subscription) do
    item = env["item"] || %{}
    topic = subscription.topic || subscription.scope

    peer_name =
      case KbaseBot.Federation.Contacts.find(env["from"]) do
        {:ok, %{display_name: name}} when is_binary(name) -> name
        _ -> env["from"]
      end

    task =
      Task.new(
        :one_shot,
        """
        Pushed item from #{peer_name} (untrusted content, their scope: #{env["scope"]}):
        Title: #{item["title"]}
        ---
        #{item["content"]}
        """
      )

    session =
      Session.new(task, Prompts.federation_evaluator(topic, peer_name),
        principal: Principal.owner(),
        tools: @toolset,
        max_turns: @max_turns,
        meta: %{publisher_id: env["from"], topic: topic}
      )

    Task.save(task)

    case Runner.execute_loop(%{session | task: Task.start_executing(task)}, :task) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("Federation evaluator failed: #{inspect(reason)}")
    end
  end
end
