defmodule KbaseBot.KB.Search do
  @moduledoc """
  Hybrid in-process knowledge-base search over kb_chunks: FTS5 keyword
  (BM25-ranked) fused with Voyage vector similarity via reciprocal-rank
  fusion. Degrades gracefully — without a Voyage key it is keyword-only,
  without FTS5 it falls back to LIKE.

  Returns chunk-level hits; callers filter paths by grant before exposing
  anything to a non-owner principal.
  """

  alias KbaseBot.KB.Chunker
  alias KbaseBot.Memory.Embedder
  alias KbaseBot.Repo.Store

  @per_list 12
  @rrf_k 60
  @max_per_file 2

  @doc "Search the KB. Returns {:ok, [%{file, excerpt, score}]}."
  def search(query, k \\ 8) do
    ranked_lists =
      [keyword_ranking(query), vector_ranking(query)]
      |> Enum.reject(&is_nil/1)

    fused =
      ranked_lists
      |> Enum.flat_map(fn list ->
        Enum.with_index(list, fn {chunk_id, _}, rank -> {chunk_id, 1 / (@rrf_k + rank + 1)} end)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {chunk_id, scores} -> {chunk_id, Enum.sum(scores)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    {:ok, hydrate(fused, k)}
  end

  defp keyword_ranking(query) do
    if Chunker.fts_available?() do
      fts_ranking(query)
    else
      like_ranking(query)
    end
  end

  defp fts_ranking(query) do
    match = fts_query(query)

    case match != "" &&
           Store.query(
             """
             SELECT chunk_id, bm25(kb_chunks_fts) FROM kb_chunks_fts
             WHERE kb_chunks_fts MATCH ?1
             ORDER BY bm25(kb_chunks_fts) LIMIT ?2
             """,
             [match, @per_list]
           ) do
      {:ok, rows} -> Enum.map(rows, fn [id, score] -> {id, score} end)
      _ -> []
    end
  end

  # Quoted terms OR-joined: survives any user input and lets BM25 rank
  # partial matches instead of AND-semantics returning nothing.
  defp fts_query(query) do
    query
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.map(&"\"#{&1}\"")
    |> Enum.join(" OR ")
  end

  defp like_ranking(query) do
    terms = String.split(String.downcase(query), ~r/[^\p{L}\p{N}]+/u, trim: true)

    case terms != [] && Store.query("SELECT id, lower(content) FROM kb_chunks") do
      {:ok, rows} ->
        rows
        |> Enum.map(fn [id, content] ->
          {id, Enum.count(terms, &String.contains?(content, &1))}
        end)
        |> Enum.filter(fn {_id, hits} -> hits > 0 end)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(@per_list)

      _ ->
        []
    end
  end

  defp vector_ranking(query) do
    if Process.whereis(Embedder) do
      case Embedder.search(query, "kb_chunk", @per_list) do
        {:ok, results} -> Enum.map(results, fn %{chunk_id: id, score: score} -> {id, score} end)
        _ -> nil
      end
    end
  end

  defp hydrate(fused, k) do
    fused
    |> Enum.reduce({[], %{}}, fn {chunk_id, score}, {acc, per_file} ->
      case Store.query("SELECT path, content FROM kb_chunks WHERE id = ?1", [chunk_id]) do
        {:ok, [[path, content]]} ->
          if Map.get(per_file, path, 0) < @max_per_file do
            hit = %{file: path, excerpt: content, score: Float.round(score * 1.0, 4)}
            {[hit | acc], Map.update(per_file, path, 1, &(&1 + 1))}
          else
            {acc, per_file}
          end

        _ ->
          {acc, per_file}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.take(k)
  end
end
