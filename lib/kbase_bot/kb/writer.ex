defmodule KbaseBot.KB.Writer do
  @moduledoc """
  Write-through layer for every server-side knowledge-base mutation.

  Files on disk are a materialized view; the durable record is the `kb_writes`
  append-only log in SQLite (replicated off-host with the rest of the DB).
  `materialize!/0` replays the log over the decrypted vault baseline on boot,
  which is what makes the host disposable: a fresh server needs only the vault
  and a restored DB to reconstruct every file the bot ever wrote.

  Owner-authored KB content never passes through here and is never touched by
  materialization — only paths present in `kb_writes` are rebuilt.

  Every record carries provenance (`actor`, `source`, `meta`), so the corpus
  export can derive training data straight from this log.
  """

  require Logger
  alias KbaseBot.Repo.Store

  def write(rel_path, content, opts \\ []), do: record("write", rel_path, content, opts)
  def append(rel_path, content, opts \\ []), do: record("append", rel_path, content, opts)
  def delete(rel_path, opts \\ []), do: record("delete", rel_path, nil, opts)

  @doc """
  Rebuild every bot-written file from the kb_writes log. Idempotent; called on
  boot after the vault baseline is on disk. Owner-authored paths are untouched.
  """
  def materialize! do
    case Store.query("SELECT path, op, content FROM kb_writes ORDER BY id") do
      {:ok, rows} ->
        rows
        |> Enum.group_by(fn [path, _op, _content] -> path end)
        |> Enum.each(fn {path, ops} -> materialize_path(path, ops) end)

        :ok

      other ->
        Logger.error("KB materialization failed to read kb_writes: #{inspect(other)}")
        :error
    end
  end

  defp record(op, rel_path, content, opts) do
    with {:ok, full} <- safe_path(rel_path) do
      snapshot_if_needed(op, rel_path, full)

      case apply_to_disk(op, full, content) do
        :ok ->
          log_write(op, rel_path, content, opts)
          KbaseBot.KB.Chunker.index_path(rel_path)
          {:ok, rel_path}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Appending to a file the log has never seen (e.g. an owner-authored file)
  # would make the log's replay lose the base content. Snapshot it as a
  # 'write' first so materialization stays self-contained.
  defp snapshot_if_needed("append", rel_path, full) do
    with {:ok, [[0]]} <-
           Store.query("SELECT COUNT(*) FROM kb_writes WHERE path = ?1", [rel_path]),
         {:ok, base} <- File.read(full) do
      log_write("write", rel_path, base, actor: "system", source: "snapshot")
    else
      _ -> :ok
    end
  end

  defp snapshot_if_needed(_op, _rel, _full), do: :ok

  defp apply_to_disk("write", full, content) do
    with :ok <- File.mkdir_p(Path.dirname(full)), do: File.write(full, content)
  end

  defp apply_to_disk("append", full, content) do
    with :ok <- File.mkdir_p(Path.dirname(full)), do: File.write(full, content, [:append])
  end

  defp apply_to_disk("delete", full, _content) do
    case File.rm(full) do
      :ok -> :ok
      # replay over a baseline that never had the file
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The write succeeded on disk; a failed log entry loses durability, not the
  # user's data — log loudly instead of failing the tool call.
  defp log_write(op, rel_path, content, opts) do
    result =
      Store.execute(
        """
        INSERT INTO kb_writes (ts, path, op, content, actor, source, meta)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """,
        [
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          rel_path,
          op,
          content,
          Keyword.get(opts, :actor, "bot"),
          Keyword.get(opts, :source, "unknown"),
          Jason.encode!(Keyword.get(opts, :meta, %{}))
        ]
      )

    case result do
      :ok -> :ok
      other -> Logger.error("kb_writes log failed for #{op} #{rel_path}: #{inspect(other)}")
    end
  end

  defp materialize_path(rel_path, ops) do
    with {:ok, full} <- safe_path(rel_path) do
      final =
        Enum.reduce(ops, :absent, fn [_path, op, content], acc ->
          case {op, acc} do
            {"write", _} -> {:file, content}
            {"append", {:file, base}} -> {:file, base <> content}
            {"append", :absent} -> {:file, content}
            {"delete", _} -> :absent
          end
        end)

      case final do
        {:file, content} -> apply_to_disk("write", full, content)
        :absent -> apply_to_disk("delete", full, nil)
      end
    else
      err -> Logger.error("KB materialization skipped #{rel_path}: #{inspect(err)}")
    end
  end

  defp safe_path(rel_path) do
    root = Path.expand(KbaseBot.Context.Server.repo_path())
    full = Path.expand(Path.join(root, rel_path))

    if String.starts_with?(full, root <> "/") do
      {:ok, full}
    else
      {:error, "path escapes the knowledge base: #{rel_path}"}
    end
  end
end
