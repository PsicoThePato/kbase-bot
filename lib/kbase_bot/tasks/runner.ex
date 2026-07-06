defmodule KbaseBot.Tasks.Runner do
  @moduledoc """
  Runs a task asynchronously under TaskSupervisor.
  Handles the LLM tool-use loop: call LLM → execute tools → send results → repeat.
  Adapted from aifred-web's subtask_executor.
  """

  require Logger

  alias KbaseBot.LLM.Client
  alias KbaseBot.Tasks.{Session, Task}
  alias KbaseBot.Tools.Registry

  @max_turns 20

  def run(%Session{} = session, manager_pid) do
    result =
      try do
        started = %{session | task: Task.start_executing(session.task)}
        Session.save(started)
        execute_loop(started, :task)
      rescue
        e ->
          Logger.error(
            "Task #{session.task.id} crashed: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          persist_failure(session, Exception.message(e))
          {:error, {:task_crashed, Exception.message(e)}}
      catch
        kind, reason ->
          Logger.error("Task #{session.task.id} #{kind}: #{inspect(reason)}")
          persist_failure(session, inspect(reason))
          {:error, {:task_crashed, inspect(reason)}}
      end

    send(manager_pid, {:task_complete, session.task.id, result})
  end

  defp persist_failure(session, reason) do
    Session.save(%{session | task: Task.fail(session.task, reason)})
  rescue
    e -> Logger.error("Task #{session.task.id}: couldn't persist failure: #{inspect(e)}")
  catch
    kind, r ->
      Logger.error("Task #{session.task.id}: couldn't persist failure: #{kind} #{inspect(r)}")
  end

  def execute_loop(%Session{} = session, layer) do
    if session.turn >= @max_turns do
      {:error, "max turns (#{@max_turns}) exceeded"}
    else
      tools = Registry.for_layer(layer)

      case Client.chat(session.system_prompt, session.task.messages,
             model: session.model,
             tools: tools
           ) do
        {:ok, response} ->
          session =
            session
            |> Session.push_assistant(response)
            |> Session.increment_turn()

          tool_calls = Client.extract_tool_calls(response)

          if tool_calls == [] do
            # No tool calls — LLM is done
            text = Client.extract_text(response)
            task = Task.complete(session.task, text)
            Session.save(%{session | task: task})
            {:ok, session}
          else
            # Execute tools, send results back, loop
            results =
              execute_tools(tool_calls, %{
                manager_pid: self(),
                principal: session.principal || KbaseBot.Principal.owner(),
                notify_chat_id: session.notify_chat_id
              })
            session = Session.push_tool_results(session, results)
            Session.save(session)
            execute_loop(session, layer)
          end

        {:error, reason} ->
          task = Task.fail(session.task, inspect(reason))
          Session.save(%{session | task: task})
          {:error, reason}
      end
    end
  end

  defp execute_tools(tool_calls, context) do
    Enum.map(tool_calls, fn %{id: id, name: name, input: input} ->
      Logger.info("Executing tool: #{name}")

      try do
        case Registry.execute(name, input, context) do
          {:ok, result} ->
            %{tool_use_id: id, content: result}

          {:error, reason} ->
            Logger.warning("Tool #{name} failed: #{reason}")
            %{tool_use_id: id, content: "Error: #{reason}", is_error: true}
        end
      rescue
        e ->
          Logger.error("Tool #{name} crashed: #{inspect(e)}")
          %{tool_use_id: id, content: "Error: tool crashed", is_error: true}
      end
    end)
  end
end
