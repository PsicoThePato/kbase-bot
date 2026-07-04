defmodule KbaseBot.Manager do
  @moduledoc """
  The Manager is an LLM conversation layer — equivalent to aifred-web's actor_worker.
  It receives batched messages from Ingress, decides what to do via tool calls,
  and manages spawned tasks.

  The Manager itself IS an LLM conversation with tools for task management,
  journaling, scheduling, etc. No hardcoded routing.
  """
  use GenServer

  require Logger

  alias KbaseBot.LLM.{Client, Prompts}
  alias KbaseBot.Tasks.{Task, Session, Runner}
  alias KbaseBot.Tools.Registry

  @max_turns 10
  @conversation_window 20

  defstruct [
    :conversation_messages,
    :active_tasks,
    :chat_id,
    # ref of the in-flight LLM call (nil when idle) + which loop turn it is
    :llm_ref,
    llm_turn: 0,
    # whether the respond tool was called at any point in the current loop
    llm_responded: false,
    # inputs that arrived while an LLM loop was running (newest first)
    pending_inputs: []
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # --- Public API (called from Ingress, returns immediately) ---

  def process(messages) do
    GenServer.cast(__MODULE__, {:process, messages})
  end

  def schedule_fire(payload) do
    GenServer.cast(__MODULE__, {:schedule_fire, payload})
  end

  # --- Server ---

  @impl true
  def init(_) do
    chat_id = Application.fetch_env!(:kbase_bot, :telegram_chat_id)
    conversation = load_conversation_history()

    Logger.info("Manager started with #{length(conversation)} messages in history")

    {:ok,
     %__MODULE__{
       conversation_messages: conversation,
       active_tasks: %{},
       chat_id: chat_id
     }}
  end

  @impl true
  def handle_cast({:process, messages}, state) do
    now = DateTime.now!(Application.get_env(:kbase_bot, :timezone, "America/Sao_Paulo"))
    time_str = Calendar.strftime(now, "%H:%M")
    day_name = day_of_week_name(locale(), Date.day_of_week(DateTime.to_date(now)))

    user_content =
      "[System] Current time: #{time_str} #{now.zone_abbr} (#{day_name})\n\n" <>
        Enum.map_join(messages, "\n", & &1)

    {:noreply, enqueue_input(state, user_content)}
  end

  @impl true
  def handle_cast({:schedule_fire, payload}, state) do
    {:noreply, enqueue_input(state, "[System] Schedule fired:\n#{payload}")}
  end

  # Result of the in-flight LLM call (spawned by start_llm_turn).
  # Must come before the catch-all {ref, _result} clause below.
  @impl true
  def handle_info({ref, result}, %__MODULE__{llm_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_llm_result(result, %{state | llm_ref: nil})}
  end

  # The in-flight LLM call crashed before returning a result.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{llm_ref: ref} = state) do
    Logger.error("Manager LLM task crashed: #{inspect(reason)}")
    KbaseBot.Telegram.send_message(state.chat_id, "Something went wrong. Try again.")
    {:noreply, finish_llm_loop(%{state | llm_ref: nil})}
  end

  # Handle the Task.Supervisor.async_nolink ref message (ignore it)
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  # Handle DOWN messages from monitored tasks
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:task_complete, task_id, result}, state) do
    Logger.info("Task #{task_id} completed")

    {text, state} =
      case result do
        {:ok, session} ->
          text = Task.extract_last_assistant_text(session.task) || "(task completed with no text)"
          state = put_in(state.active_tasks, Map.delete(state.active_tasks, task_id))
          {text, state}

        {:error, reason} ->
          state = put_in(state.active_tasks, Map.delete(state.active_tasks, task_id))
          {"Task failed: #{inspect(reason)}", state}
      end

    # Inject task completion as a system notification and let manager respond
    notification = "[System] Background task #{task_id} completed.\nResult:\n#{text}"
    {:noreply, enqueue_input(state, notification)}
  end

  # --- Manager LLM loop ---
  #
  # The LLM call runs in a Task so the Manager keeps handling Telegram
  # messages, schedule fires and task completions while waiting (the client
  # also sleeps between retries — up to a minute — which must not block us).
  # Inputs that arrive mid-loop are buffered and drained at the next loop
  # boundary, so they never split an assistant tool_use from its tool_result.

  defp enqueue_input(state, content) do
    if state.llm_ref == nil do
      %{state | llm_responded: false}
      |> append_message(%{"role" => "user", "content" => content})
      |> start_llm_turn(0)
    else
      %{state | pending_inputs: [content | state.pending_inputs]}
    end
  end

  defp start_llm_turn(state, turn) do
    tools = Registry.for_layer(:manager)
    system_prompt = Prompts.manager()

    window =
      state.conversation_messages
      |> Enum.take(-@conversation_window)
      |> trim_orphan_tool_use()

    task =
      Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
        Client.chat(system_prompt, window, tools: tools)
      end)

    %{state | llm_ref: task.ref, llm_turn: turn}
  end

  defp handle_llm_result({:ok, response}, state) do
    state = append_message(state, %{"role" => "assistant", "content" => response["content"]})

    case Client.extract_tool_calls(response) do
      [] ->
        # LLM is done — no more tool calls. If it never called respond, its
        # final text was meant for the user; deliver it instead of dropping it.
        text = Client.extract_text(response) |> String.trim()

        if not state.llm_responded and text != "" do
          KbaseBot.Telegram.send_message(state.chat_id, text)
        end

        finish_llm_loop(state)

      tool_calls ->
        {results, state} = execute_manager_tools(tool_calls, state)
        state = append_tool_results(state, results)

        state =
          if Enum.any?(tool_calls, &(&1.name == "respond")) do
            %{state | llm_responded: true}
          else
            state
          end

        if state.llm_turn + 1 >= @max_turns do
          Logger.warning("Manager: max turns exceeded")
          finish_llm_loop(state)
        else
          start_llm_turn(state, state.llm_turn + 1)
        end
    end
  end

  defp handle_llm_result({:error, :llm_budget_exceeded}, state) do
    Logger.warning("Manager LLM call refused: daily budget exhausted")

    KbaseBot.Telegram.send_message(
      state.chat_id,
      "I've hit today's LLM call budget, so I'm pausing until midnight UTC. " <>
        "If you weren't expecting this, something may be looping — check the schedules. " <>
        "You can raise DAILY_LLM_CALL_BUDGET if today just ran hot."
    )

    finish_llm_loop(state)
  end

  defp handle_llm_result({:error, reason}, state) do
    Logger.error("Manager LLM call failed: #{inspect(reason)}")
    KbaseBot.Telegram.send_message(state.chat_id, "Something went wrong. Try again.")
    finish_llm_loop(state)
  end

  # Loop finished: drain any inputs that arrived while it ran.
  defp finish_llm_loop(%{pending_inputs: []} = state), do: state

  defp finish_llm_loop(state) do
    state =
      state.pending_inputs
      |> Enum.reverse()
      |> Enum.reduce(state, fn content, acc ->
        append_message(acc, %{"role" => "user", "content" => content})
      end)

    start_llm_turn(%{state | pending_inputs: [], llm_responded: false}, 0)
  end

  defp append_tool_results(state, results) do
    blocks =
      Enum.map(results, fn result ->
        block = %{
          "type" => "tool_result",
          "tool_use_id" => result.tool_use_id,
          "content" => result.content
        }

        if result[:is_error], do: Map.put(block, "is_error", true), else: block
      end)

    append_message(state, %{"role" => "user", "content" => blocks})
  end

  defp execute_manager_tools(tool_calls, state) do
    context = %{chat_id: state.chat_id, manager_pid: self(), active_tasks: state.active_tasks}

    {results, state} =
      Enum.map_reduce(tool_calls, state, fn %{id: id, name: name, input: input}, acc_state ->
        Logger.info("Manager tool: #{name}")

        case name do
          "spawn_task" ->
            {result, acc_state} = handle_spawn_task(input, acc_state)
            {%{tool_use_id: id, content: result}, acc_state}

          "cancel_task" ->
            {result, acc_state} = handle_cancel_task(input, acc_state)
            {%{tool_use_id: id, content: result}, acc_state}

          "message_task" ->
            {result, acc_state} = handle_message_task(input, acc_state)
            {%{tool_use_id: id, content: result}, acc_state}

          _ ->
            try do
              case Registry.execute(name, input, context) do
                {:ok, result} ->
                  {%{tool_use_id: id, content: result}, acc_state}

                {:error, reason} ->
                  {%{tool_use_id: id, content: "Error: #{reason}", is_error: true}, acc_state}
              end
            rescue
              e ->
                Logger.error("Tool #{name} crashed: #{inspect(e)}")
                {%{tool_use_id: id, content: "Error: tool crashed", is_error: true}, acc_state}
            end
        end
      end)

    {results, state}
  end

  defp handle_spawn_task(%{"description" => description}, state) do
    user_profile = KbaseBot.Context.Server.get_user_profile()
    system_prompt = Prompts.task_execution(user_profile)

    task = Task.new(:one_shot, description)
    session = Session.new(task, system_prompt)
    Task.save(task)

    # Spawn under TaskSupervisor
    manager_pid = self()

    Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
      Runner.run(session, manager_pid)
    end)

    state = put_in(state.active_tasks, Map.put(state.active_tasks, task.id, task))
    {"Task #{task.id} spawned.", state}
  end

  defp handle_cancel_task(%{"task_id" => task_id}, state) do
    case Map.get(state.active_tasks, task_id) do
      nil ->
        {"Task #{task_id} not found in active tasks.", state}

      _task ->
        # Mark as failed in DB
        case Task.find(task_id) do
          {:ok, task} ->
            task = Task.fail(task, "cancelled")
            Task.save(task)

          _ ->
            :ok
        end

        state = put_in(state.active_tasks, Map.delete(state.active_tasks, task_id))
        {"Task #{task_id} cancelled.", state}
    end
  end

  defp handle_message_task(%{"task_id" => task_id, "message" => message}, state) do
    case Task.find(task_id) do
      {:ok, task} when task.state in [:done, :failed] ->
        # Resume with follow-up
        user_profile = KbaseBot.Context.Server.get_user_profile()
        system_prompt = Prompts.task_execution(user_profile)

        task = Task.follow_up(task, message)
        session = Session.new(task, system_prompt)
        Task.save(task)

        manager_pid = self()

        Elixir.Task.Supervisor.async_nolink(KbaseBot.TaskSupervisor, fn ->
          Runner.run(session, manager_pid)
        end)

        state = put_in(state.active_tasks, Map.put(state.active_tasks, task_id, task))
        {"Message sent to task #{task_id}, resuming.", state}

      {:ok, _task} ->
        {"Task #{task_id} is still running and cannot receive messages mid-flight. " <>
           "Wait for it to complete, then message it again to resume with your follow-up.", state}

      {:error, :not_found} ->
        {"Task #{task_id} not found.", state}
    end
  end

  # The API requires the first message to be a "user" message and every
  # tool_use to be answered by a tool_result — window slicing can violate
  # both, so drop leading assistant messages and orphaned tool exchanges.
  # Public for tests only.
  @doc false
  def trim_orphan_tool_use([]), do: []

  def trim_orphan_tool_use([%{"role" => "assistant", "content" => content} | rest]) do
    has_tool_use =
      is_list(content) and Enum.any?(content, fn b -> is_map(b) and b["type"] == "tool_use" end)

    if has_tool_use do
      case rest do
        [%{"role" => "user", "content" => c} | rest2] when is_list(c) ->
          has_tool_result = Enum.any?(c, fn b -> is_map(b) and b["type"] == "tool_result" end)
          if has_tool_result, do: trim_orphan_tool_use(rest2), else: trim_orphan_tool_use(rest)

        _ ->
          trim_orphan_tool_use(rest)
      end
    else
      trim_orphan_tool_use(rest)
    end
  end

  def trim_orphan_tool_use([%{"role" => "user", "content" => content} | rest] = msgs)
      when is_list(content) do
    has_tool_result = Enum.any?(content, fn b -> is_map(b) and b["type"] == "tool_result" end)
    if has_tool_result, do: trim_orphan_tool_use(rest), else: msgs
  end

  def trim_orphan_tool_use(msgs), do: msgs

  # --- Message persistence ---

  defp append_message(state, message) do
    messages = state.conversation_messages ++ [message]
    messages = if length(messages) > 200, do: Enum.take(messages, -200), else: messages

    # Persist to SQLite
    content =
      case message["content"] do
        c when is_binary(c) -> c
        c -> Jason.encode!(c)
      end

    KbaseBot.Repo.Store.execute(
      "INSERT INTO manager_messages (role, content) VALUES (?1, ?2)",
      [message["role"], content]
    )

    %{state | conversation_messages: messages}
  end

  defp load_conversation_history do
    case KbaseBot.Repo.Store.query(
           "SELECT role, content FROM manager_messages ORDER BY id DESC LIMIT 100"
         ) do
      {:ok, rows} ->
        rows
        |> Enum.reverse()
        |> Enum.map(fn [role, content] ->
          parsed_content =
            case Jason.decode(content) do
              {:ok, decoded} -> decoded
              {:error, _} -> content
            end

          %{"role" => role, "content" => parsed_content}
        end)

      _ ->
        []
    end
  end

  # --- Helpers ---

  defp locale, do: Application.get_env(:kbase_bot, :locale, "pt")

  @day_names %{
    "pt" => ~w(Segunda-feira Terca-feira Quarta-feira Quinta-feira Sexta-feira Sabado Domingo),
    "en" => ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  }

  defp day_of_week_name(locale, day) do
    @day_names
    |> Map.get(locale, @day_names["en"])
    |> Enum.at(day - 1)
  end
end
