defmodule KbaseBot.KB.Chunker do
  @moduledoc """
  Splits knowledge-base markdown into chunks and keeps the kb_chunks table
  (plus its FTS5 mirror) in sync with the files on disk. Chunks are inserted
  with embedded_at NULL; the Embedder picks them up on its next poll, so
  vector search lags a file change by at most one poll interval while keyword
  search is current immediately.

  Pure functions over the Store — no process. Called from boot (full reindex),
  from KB.Writer after each mutation, and from the refresh_context tool.
  """

  require Logger
  alias KbaseBot.Repo.Store

  # Sections bigger than this split at paragraph boundaries; smaller ones merge.
  @max_chunk 1600
  @min_chunk 200

  def reindex_all do
    root = KbaseBot.Context.Server.repo_path()

    on_disk =
      root
      |> find_markdown()
      |> MapSet.new()

    Enum.each(on_disk, &index_path/1)

    # drop chunks for files that no longer exist
    case Store.query("SELECT DISTINCT path FROM kb_chunks") do
      {:ok, rows} ->
        for [path] <- rows, not MapSet.member?(on_disk, path), do: drop_path(path)

      _ ->
        :ok
    end

    :ok
  end

  @doc "Re-chunk one file (relative path); removes its chunks if the file is gone."
  def index_path(rel_path) do
    if Path.extname(rel_path) == ".md" do
      full = Path.join(KbaseBot.Context.Server.repo_path(), rel_path)

      case File.read(full) do
        {:ok, content} -> sync_chunks(rel_path, chunk(content))
        {:error, :enoent} -> drop_path(rel_path)
        {:error, reason} -> Logger.warning("chunker skipped #{rel_path}: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc "Split markdown into search-sized chunks. Public for tests."
  def chunk(content) do
    content
    |> String.split(~r/^(?=#+ )/m)
    |> Enum.flat_map(&split_large/1)
    |> merge_small()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # --- sync ---

  defp sync_chunks(rel_path, chunks) do
    hashes = Enum.map(chunks, &hash/1)

    current =
      case Store.query("SELECT content_hash FROM kb_chunks WHERE path = ?1 ORDER BY idx", [
             rel_path
           ]) do
        {:ok, rows} -> Enum.map(rows, fn [h] -> h end)
        _ -> nil
      end

    if hashes != current do
      drop_path(rel_path)
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      chunks
      |> Enum.with_index()
      |> Enum.each(fn {text, idx} ->
        Store.execute(
          "INSERT INTO kb_chunks (path, idx, content, content_hash, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)",
          [rel_path, idx, text, Enum.at(hashes, idx), now]
        )
      end)

      if fts_available?() do
        case Store.query("SELECT id, idx, content FROM kb_chunks WHERE path = ?1", [rel_path]) do
          {:ok, rows} ->
            Enum.each(rows, fn [id, _idx, text] ->
              Store.execute(
                "INSERT INTO kb_chunks_fts (chunk_id, path, content) VALUES (?1, ?2, ?3)",
                [id, rel_path, text]
              )
            end)

          _ ->
            :ok
        end
      end
    end

    :ok
  end

  defp drop_path(rel_path) do
    case Store.query("SELECT id FROM kb_chunks WHERE path = ?1", [rel_path]) do
      {:ok, rows} ->
        Enum.each(rows, fn [id] ->
          Store.execute(
            "DELETE FROM embeddings WHERE source_type = 'kb_chunk' AND source_id = ?1",
            [to_string(id)]
          )
        end)

      _ ->
        :ok
    end

    if fts_available?() do
      Store.execute("DELETE FROM kb_chunks_fts WHERE path = ?1", [rel_path])
    end

    Store.execute("DELETE FROM kb_chunks WHERE path = ?1", [rel_path])
  end

  def fts_available? do
    case Store.query(
           "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'kb_chunks_fts'"
         ) do
      {:ok, [_]} -> true
      _ -> false
    end
  end

  # --- file walk ---

  defp find_markdown(root) do
    root
    |> walk(".")
    |> Enum.filter(&(Path.extname(&1) == ".md"))
  end

  defp walk(root, rel) do
    full = Path.join(root, rel)

    cond do
      # .vault, .git and friends never get indexed
      String.starts_with?(Path.basename(rel), ".") and rel != "." ->
        []

      File.dir?(full) ->
        case File.ls(full) do
          {:ok, entries} ->
            Enum.flat_map(entries, fn entry ->
              walk(root, if(rel == ".", do: entry, else: Path.join(rel, entry)))
            end)

          _ ->
            []
        end

      true ->
        [rel]
    end
  end

  # --- chunking helpers ---

  defp split_large(section) when byte_size(section) <= @max_chunk, do: [section]

  defp split_large(section) do
    section
    |> String.split("\n\n")
    |> Enum.reduce([], fn para, acc ->
      case acc do
        [head | rest] when byte_size(head) + byte_size(para) + 2 <= @max_chunk ->
          [head <> "\n\n" <> para | rest]

        _ ->
          [para | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp merge_small(chunks) do
    chunks
    |> Enum.reduce([], fn chunk, acc ->
      case acc do
        [head | rest] when byte_size(head) < @min_chunk ->
          [head <> "\n" <> chunk | rest]

        _ ->
          [chunk | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
