defmodule Mix.Tasks.KbaseBot.Corpus.Export do
  @shortdoc "Export the training corpus (conversation, journal, KB writes, task outcomes) to JSONL"

  @moduledoc """
  Dumps corpus records from the SQLite DB into the knowledge base, in the
  guardian-angel record format (see knowledge_base/guardian_angel/README.md).

      mix kbase_bot.corpus.export [--db path/to/repo.db] [--out dir]

  Defaults: `--db` from $DB_PATH or priv/repo.db; `--out` from
  $REPO_PATH/corpus or ../knowledge_base/corpus. Reads the DB directly —
  the app does not need to be running or configured. Idempotent: rewrites
  the whole export file each run (append-only history lives in the DB).
  """

  use Mix.Task

  @impl true
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [db: :string, out: :string])

    db_path = opts[:db] || System.get_env("DB_PATH") || "priv/repo.db"
    out_dir = opts[:out] || default_out_dir()

    unless File.exists?(db_path), do: Mix.raise("DB not found: #{db_path}")
    File.mkdir_p!(out_dir)

    out_path = Path.join(out_dir, "export-#{Date.utc_today()}.jsonl")
    {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readonly)

    records =
      messages(conn) ++ kb_writes(conn) ++ task_outcomes(conn)

    out = File.open!(out_path, [:write, :utf8])
    Enum.each(records, &IO.write(out, [Jason.encode!(&1), "\n"]))
    File.close(out)
    Exqlite.Sqlite3.close(conn)

    Mix.shell().info("wrote #{length(records)} records -> #{out_path}")
  end

  defp default_out_dir do
    repo = System.get_env("REPO_PATH") || "../knowledge_base"
    Path.join(repo, "corpus")
  end

  defp messages(conn) do
    for [role, content, ts] <-
          all(conn, "SELECT role, content, created_at FROM manager_messages ORDER BY id") do
      {text, blocks} = extract_text(content)

      %{
        ts: ts,
        source: "export:manager_messages",
        author: author_for(role, blocks),
        sensitivity: "personal",
        kind: "message",
        text: text,
        meta: %{role: role, blocks: blocks}
      }
    end
  end

  defp kb_writes(conn) do
    for [ts, path, op, content, actor, source, meta] <-
          all(
            conn,
            "SELECT ts, path, op, content, actor, source, meta FROM kb_writes ORDER BY id"
          ) do
      %{
        ts: ts,
        source: "export:kb_writes:#{source}",
        author: actor,
        sensitivity: "personal",
        kind: if(source == "journal", do: "journal", else: "kb_write"),
        text: content || "",
        meta: Map.merge(decode(meta), %{path: path, op: op})
      }
    end
  end

  defp task_outcomes(conn) do
    for [id, outcome, state, ts] <-
          all(conn, "SELECT id, outcome, state, updated_at FROM tasks ORDER BY created_at") do
      %{
        ts: ts,
        source: "export:tasks",
        author: "bot",
        sensitivity: "personal",
        kind: "outcome",
        text: outcome || "",
        meta: %{task_id: id, state: state}
      }
    end
  end

  # manager_messages.content is plain text or a JSON array of content blocks
  defp extract_text(content) do
    case Jason.decode(content) do
      {:ok, blocks} when is_list(blocks) ->
        text =
          blocks
          |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
          |> Enum.map_join("\n", & &1["text"])

        {text, blocks |> Enum.map(&(is_map(&1) && &1["type"])) |> Enum.uniq()}

      _ ->
        {content, nil}
    end
  end

  defp author_for("assistant", _blocks), do: "bot"
  defp author_for(_role, nil), do: "jairo"
  defp author_for(_role, _blocks), do: "system"

  defp decode(json) do
    case Jason.decode(json || "{}") do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp all(conn, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    rows = fetch(conn, stmt, [])
    Exqlite.Sqlite3.release(conn, stmt)
    rows
  end

  defp fetch(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
