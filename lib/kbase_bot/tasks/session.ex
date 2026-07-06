defmodule KbaseBot.Tasks.Session do
  @moduledoc """
  TaskSession: wraps a Task with LLM execution state.
  Adapted from aifred-web's TaskSession.
  """

  alias KbaseBot.Tasks.Task

  defstruct [
    :task,
    :model,
    :turn,
    :system_prompt,
    :needs_planning,
    # Principal this session runs as — tools are policy-gated against it.
    :principal,
    # Where notify_user delivers; nil falls back to the owner chat id.
    :notify_chat_id
  ]

  def new(%Task{} = task, system_prompt, opts \\ []) do
    %__MODULE__{
      task: task,
      model: Keyword.get(opts, :model) || Application.fetch_env!(:kbase_bot, :model),
      turn: 0,
      system_prompt: system_prompt,
      needs_planning: Keyword.get(opts, :needs_planning, false),
      principal: Keyword.get(opts, :principal) || KbaseBot.Principal.owner(),
      notify_chat_id: Keyword.get(opts, :notify_chat_id)
    }
  end

  def push_message(%__MODULE__{} = session, message) do
    %{session | task: Task.append_message(session.task, message)}
  end

  def push_assistant(%__MODULE__{} = session, response) do
    # Store the raw content array from Anthropic response
    content = response["content"]
    push_message(session, %{"role" => "assistant", "content" => content})
  end

  def push_tool_results(%__MODULE__{} = session, results) do
    # results is a list of %{tool_use_id, content, is_error}
    content =
      Enum.map(results, fn result ->
        block = %{
          "type" => "tool_result",
          "tool_use_id" => result.tool_use_id,
          "content" => result.content
        }

        if result[:is_error] do
          Map.put(block, "is_error", true)
        else
          block
        end
      end)

    push_message(session, %{"role" => "user", "content" => content})
  end

  def follow_up(%__MODULE__{} = session, text) do
    %{session | task: Task.follow_up(session.task, text)}
  end

  def increment_turn(%__MODULE__{} = session) do
    %{session | turn: session.turn + 1}
  end

  def save(%__MODULE__{task: task}) do
    Task.save(task)
  end
end
