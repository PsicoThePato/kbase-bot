defmodule KbaseBot.Tasks.Task do
  @moduledoc """
  Task struct and state machine.
  Adapted from aifred-web's Task domain.
  """

  @type state :: :pending | :planning | :executing | :done | :failed
  @type task_type :: :conversation | :one_shot

  defstruct [
    :id,
    :state,
    :task_type,
    :plan,
    :messages,
    :outcome,
    :status_message,
    :created_at,
    :updated_at
  ]

  def new(task_type, input) do
    now = now_iso()

    messages =
      if input != "" do
        [%{"role" => "user", "content" => input}]
      else
        []
      end

    %__MODULE__{
      id: generate_id(),
      state: :pending,
      task_type: task_type,
      plan: nil,
      messages: messages,
      outcome: nil,
      status_message: nil,
      created_at: now,
      updated_at: now
    }
  end

  def start_executing(%__MODULE__{} = task) do
    %{task | state: :executing, updated_at: now_iso()}
  end

  def complete(%__MODULE__{} = task, result) do
    %{task | state: :done, outcome: {:success, result}, updated_at: now_iso()}
  end

  def fail(%__MODULE__{} = task, reason) do
    %{task | state: :failed, outcome: {:failed, reason}, updated_at: now_iso()}
  end

  def append_message(%__MODULE__{} = task, message) do
    messages = task.messages ++ [message]
    %{task | messages: messages, updated_at: now_iso()}
  end

  def follow_up(%__MODULE__{} = task, text) do
    task
    |> append_message(%{"role" => "user", "content" => text})
    |> Map.put(:state, :executing)
    |> Map.put(:outcome, nil)
    |> Map.put(:updated_at, now_iso())
  end

  def extract_last_assistant_text(%__MODULE__{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "assistant", "content" => content} when is_binary(content) ->
        content

      %{"role" => "assistant", "content" => blocks} when is_list(blocks) ->
        blocks
        |> Enum.find_value(fn
          %{"type" => "text", "text" => text} -> text
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  # --- Persistence ---

  def save(%__MODULE__{} = task) do
    KbaseBot.Repo.Store.execute(
      """
      INSERT OR REPLACE INTO tasks (id, state, task_type, plan, messages, outcome, status_message, created_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
      """,
      [
        task.id,
        Atom.to_string(task.state),
        Atom.to_string(task.task_type),
        task.plan,
        Jason.encode!(task.messages),
        encode_outcome(task.outcome),
        task.status_message,
        task.created_at,
        task.updated_at
      ]
    )
  end

  def find(id) do
    case KbaseBot.Repo.Store.query("SELECT * FROM tasks WHERE id = ?1", [id]) do
      {:ok, [row]} -> {:ok, from_row(row)}
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  def find_active do
    {:ok, rows} =
      KbaseBot.Repo.Store.query(
        "SELECT * FROM tasks WHERE state IN ('pending', 'planning', 'executing') ORDER BY created_at DESC"
      )

    Enum.map(rows, &from_row/1)
  end

  defp from_row([
         id,
         state,
         task_type,
         plan,
         messages,
         outcome,
         status_message,
         created_at,
         updated_at | _
       ]) do
    %__MODULE__{
      id: id,
      state: String.to_existing_atom(state),
      task_type: String.to_existing_atom(task_type),
      plan: plan,
      messages: Jason.decode!(messages),
      outcome: decode_outcome(outcome),
      status_message: status_message,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp encode_outcome(nil), do: nil
  defp encode_outcome({:success, result}), do: Jason.encode!(%{type: "success", content: result})
  defp encode_outcome({:failed, reason}), do: Jason.encode!(%{type: "failed", content: reason})

  defp decode_outcome(nil), do: nil

  defp decode_outcome(json) do
    case Jason.decode!(json) do
      %{"type" => "success", "content" => content} -> {:success, content}
      %{"type" => "failed", "content" => content} -> {:failed, content}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp now_iso do
    Application.get_env(:kbase_bot, :timezone, "America/Sao_Paulo")
    |> DateTime.now!()
    |> DateTime.to_iso8601()
  end
end
