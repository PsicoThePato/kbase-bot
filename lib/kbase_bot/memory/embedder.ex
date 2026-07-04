defmodule KbaseBot.Memory.Embedder do
  @moduledoc """
  Periodically embeds new messages and tasks via Voyage API,
  stores vectors in SQLite, and serves semantic search queries.
  """
  use GenServer

  require Logger

  alias KbaseBot.Memory.VoyageClient
  alias KbaseBot.Repo.Store

  @batch_size 20

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def search(query, source_type, k \\ 5) do
    GenServer.call(__MODULE__, {:search, query, source_type, k}, 30_000)
  end

  # --- Server ---

  @impl true
  def init(_) do
    poll_interval = Application.get_env(:kbase_bot, :embedding_poll_interval_ms, 60_000)
    Process.send_after(self(), :poll, poll_interval)
    Logger.info("Embedder started, polling every #{poll_interval}ms")
    {:ok, %{poll_interval: poll_interval}}
  end

  @impl true
  def handle_info(:poll, state) do
    embed_new_messages()
    embed_new_tasks()
    Process.send_after(self(), :poll, state.poll_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call({:search, query, source_type, k}, _from, state) do
    result = do_search(query, source_type, k)
    {:reply, result, state}
  end

  # --- Embedding ---

  defp embed_new_messages do
    case Store.query(
           "SELECT id, content FROM manager_messages WHERE embedded_at IS NULL AND role IN ('user', 'assistant') ORDER BY id ASC LIMIT ?1",
           [@batch_size]
         ) do
      {:ok, rows} when rows != [] ->
        {ids, texts} =
          rows
          |> Enum.reject(fn [_id, content] -> json_array?(content) end)
          |> Enum.map(fn [id, content] -> {id, content} end)
          |> Enum.unzip()

        if texts != [] do
          case VoyageClient.embed(texts) do
            {:ok, embeddings} ->
              store_embeddings("message", ids, embeddings)
              Logger.info("Embedded #{length(ids)} messages")

            {:error, reason} ->
              Logger.warning("Failed to embed messages: #{inspect(reason)}")
          end
        end

      _ ->
        :ok
    end
  end

  defp embed_new_tasks do
    case Store.query(
           "SELECT id, messages, outcome FROM tasks WHERE embedded_at IS NULL AND state IN ('done', 'failed') LIMIT ?1",
           [@batch_size]
         ) do
      {:ok, rows} when rows != [] ->
        {ids, texts} =
          Enum.unzip(
            Enum.map(rows, fn [id, messages_json, outcome_json] ->
              description = extract_task_description(messages_json)
              outcome = extract_task_outcome(outcome_json)
              text = Enum.join([description, outcome] |> Enum.reject(&is_nil/1), "\n\n")
              {id, text}
            end)
          )

        if texts != [] do
          case VoyageClient.embed(texts) do
            {:ok, embeddings} ->
              store_embeddings("task", ids, embeddings)
              Logger.info("Embedded #{length(ids)} tasks")

            {:error, reason} ->
              Logger.warning("Failed to embed tasks: #{inspect(reason)}")
          end
        end

      _ ->
        :ok
    end
  end

  defp store_embeddings(source_type, ids, embeddings) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.zip(ids, embeddings)
    |> Enum.each(fn {source_id, embedding} ->
      blob = encode_embedding(embedding)

      Store.execute(
        "INSERT INTO embeddings (source_type, source_id, embedding, created_at) VALUES (?1, ?2, ?3, ?4)",
        [source_type, to_string(source_id), blob, now]
      )

      table = if source_type == "message", do: "manager_messages", else: "tasks"

      Store.execute(
        "UPDATE #{table} SET embedded_at = ?1 WHERE id = ?2",
        [now, source_id]
      )
    end)
  end

  # --- Search ---

  defp do_search(query, source_type, k) do
    with {:ok, [query_embedding]} <- VoyageClient.embed([query]),
         {:ok, rows} <-
           Store.query(
             "SELECT source_id, embedding FROM embeddings WHERE source_type = ?1",
             [source_type]
           ) do
      if rows == [] do
        {:ok, []}
      else
        query_tensor = Nx.tensor(query_embedding, type: :f32)

        scored =
          rows
          |> Enum.map(fn [source_id, blob] ->
            embedding = decode_embedding(blob)
            tensor = Nx.tensor(embedding, type: :f32)
            score = cosine_similarity(query_tensor, tensor)
            {source_id, Nx.to_number(score)}
          end)
          |> Enum.sort_by(fn {_id, score} -> score end, :desc)
          |> Enum.take(k)

        results = fetch_source_content(source_type, scored)
        {:ok, results}
      end
    end
  end

  defp cosine_similarity(a, b) do
    dot = Nx.dot(a, b)
    norm_a = Nx.LinAlg.norm(a)
    norm_b = Nx.LinAlg.norm(b)
    Nx.divide(dot, Nx.max(Nx.multiply(norm_a, norm_b), 1.0e-8))
  end

  defp fetch_source_content("message", scored) do
    Enum.map(scored, fn {source_id, score} ->
      case Store.query(
             "SELECT role, content, created_at FROM manager_messages WHERE id = ?1",
             [source_id]
           ) do
        {:ok, [[role, content, created_at]]} ->
          %{role: role, content: content, created_at: created_at, score: score}

        _ ->
          %{role: "unknown", content: "(message not found)", created_at: nil, score: score}
      end
    end)
  end

  defp fetch_source_content("task", scored) do
    Enum.map(scored, fn {source_id, score} ->
      case Store.query(
             "SELECT task_type, state, messages, outcome, created_at FROM tasks WHERE id = ?1",
             [source_id]
           ) do
        {:ok, [[task_type, state, messages_json, outcome_json, created_at]]} ->
          %{
            task_type: task_type,
            state: state,
            description: extract_task_description(messages_json),
            outcome: extract_task_outcome(outcome_json),
            created_at: created_at,
            score: score
          }

        _ ->
          %{description: "(task not found)", score: score}
      end
    end)
  end

  # --- Helpers ---

  defp encode_embedding(floats) when is_list(floats) do
    floats
    |> Enum.map(&<<&1::float-32-little>>)
    |> IO.iodata_to_binary()
  end

  defp decode_embedding(blob) when is_binary(blob) do
    for <<f::float-32-little <- blob>>, do: f
  end

  defp json_array?(content) do
    String.starts_with?(String.trim(content), "[")
  end

  defp extract_task_description(messages_json) do
    case Jason.decode(messages_json) do
      {:ok, [%{"role" => "user", "content" => content} | _]} when is_binary(content) -> content
      _ -> nil
    end
  end

  defp extract_task_outcome(nil), do: nil

  defp extract_task_outcome(outcome_json) do
    case Jason.decode(outcome_json) do
      {:ok, %{"content" => content}} -> content
      _ -> nil
    end
  end
end
