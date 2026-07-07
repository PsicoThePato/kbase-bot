defmodule KbaseBot.Repo.Migrations do
  def run(conn) do
    migrations()
    |> Enum.each(fn sql ->
      :ok = Exqlite.Sqlite3.execute(conn, sql)
    end)

    alter_migrations()
    |> Enum.each(fn sql ->
      case Exqlite.Sqlite3.execute(conn, sql) do
        :ok -> :ok
        {:error, _} -> :ok
      end
    end)
  end

  defp migrations do
    [
      """
      CREATE TABLE IF NOT EXISTS tasks (
          id TEXT PRIMARY KEY,
          state TEXT NOT NULL DEFAULT 'pending',
          task_type TEXT NOT NULL,
          plan TEXT,
          messages TEXT NOT NULL DEFAULT '[]',
          outcome TEXT,
          status_message TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS schedules (
          id TEXT PRIMARY KEY,
          payload TEXT NOT NULL,
          cron TEXT NOT NULL,
          timezone TEXT NOT NULL DEFAULT 'America/Sao_Paulo',
          next_fire_at TEXT,
          last_fired_at TEXT,
          fire_count INTEGER NOT NULL DEFAULT 0,
          max_fires INTEGER,
          state TEXT NOT NULL DEFAULT 'active',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS idx_schedules_due ON schedules (next_fire_at)
          WHERE state = 'active' AND next_fire_at IS NOT NULL
      """,
      """
      CREATE TABLE IF NOT EXISTS manager_messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          role TEXT NOT NULL,
          content TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS journal_entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          filename TEXT NOT NULL,
          message_text TEXT NOT NULL,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS embeddings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_type TEXT NOT NULL,
          source_id TEXT NOT NULL,
          embedding BLOB NOT NULL,
          created_at TEXT NOT NULL
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS idx_embeddings_source ON embeddings (source_type)
      """,
      """
      CREATE TABLE IF NOT EXISTS llm_daily_usage (
          day TEXT PRIMARY KEY,
          calls INTEGER NOT NULL DEFAULT 0,
          alerted INTEGER NOT NULL DEFAULT 0
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS contacts (
          principal_id TEXT PRIMARY KEY,
          display_name TEXT,
          card_json TEXT NOT NULL,
          card_seq INTEGER NOT NULL DEFAULT 0,
          added_at TEXT NOT NULL,
          notes TEXT
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS grants (
          id TEXT PRIMARY KEY,
          aud TEXT NOT NULL,
          scope TEXT NOT NULL,
          caps_json TEXT NOT NULL,
          caveats_json TEXT NOT NULL DEFAULT '{}',
          record_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          revoked_at TEXT
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS idx_grants_live ON grants (aud, scope)
          WHERE revoked_at IS NULL
      """
    ]
  end

  defp alter_migrations do
    [
      "ALTER TABLE manager_messages ADD COLUMN embedded_at TEXT",
      "ALTER TABLE tasks ADD COLUMN embedded_at TEXT",
      """
      UPDATE schedules
      SET next_fire_at = strftime('%Y-%m-%dT%H:%M:%SZ', next_fire_at)
      WHERE next_fire_at IS NOT NULL AND next_fire_at NOT LIKE '%Z'
      """
    ]
  end
end
