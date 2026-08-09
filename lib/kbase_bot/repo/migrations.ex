defmodule KbaseBot.Repo.Migrations do
  @moduledoc """
  Schema v2. There is no migration machinery on purpose: the DB is disposable
  (replicated for durability, wiped on schema change); only the knowledge base
  markdown persists. Schema changes edit the CREATE statements here and reboot
  from zero.
  """

  def run(conn) do
    migrations()
    |> Enum.each(fn sql ->
      :ok = Exqlite.Sqlite3.execute(conn, sql)
    end)

    # FTS5 is compiled into exqlite's bundled SQLite everywhere we deploy, but
    # keyword search degrades to LIKE rather than the app failing to boot if a
    # build lacks it (KB.Chunker.fts_available?/0 is the runtime check).
    case Exqlite.Sqlite3.execute(
           conn,
           "CREATE VIRTUAL TABLE IF NOT EXISTS kb_chunks_fts USING fts5(chunk_id UNINDEXED, path UNINDEXED, content)"
         ) do
      :ok -> :ok
      {:error, _} -> :ok
    end
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
          embedded_at TEXT,
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
          embedded_at TEXT,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS kb_writes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts TEXT NOT NULL,
          path TEXT NOT NULL,
          op TEXT NOT NULL CHECK (op IN ('write', 'append', 'delete')),
          content TEXT,
          actor TEXT NOT NULL,
          source TEXT NOT NULL DEFAULT 'unknown',
          meta TEXT NOT NULL DEFAULT '{}'
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS idx_kb_writes_path ON kb_writes (path, id)
      """,
      """
      CREATE TABLE IF NOT EXISTS kb_chunks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT NOT NULL,
          idx INTEGER NOT NULL,
          content TEXT NOT NULL,
          content_hash TEXT NOT NULL,
          embedded_at TEXT,
          updated_at TEXT NOT NULL,
          UNIQUE (path, idx)
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
      """,
      """
      CREATE TABLE IF NOT EXISTS exchanges (
          id TEXT NOT NULL,
          direction TEXT NOT NULL,
          kind TEXT NOT NULL,
          peer TEXT NOT NULL,
          scope TEXT,
          question TEXT,
          state TEXT NOT NULL DEFAULT 'open',
          opened_at TEXT NOT NULL,
          closed_at TEXT,
          PRIMARY KEY (id, direction)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS subscriptions (
          id TEXT PRIMARY KEY,
          direction TEXT NOT NULL,
          principal_id TEXT NOT NULL,
          scope TEXT NOT NULL,
          topic TEXT,
          state TEXT NOT NULL DEFAULT 'active',
          created_at TEXT NOT NULL,
          UNIQUE (direction, principal_id, scope)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS threads (
          id TEXT PRIMARY KEY,
          role TEXT NOT NULL,
          principal_id TEXT NOT NULL,
          scope TEXT NOT NULL,
          task_id TEXT NOT NULL,
          turn_count INTEGER NOT NULL DEFAULT 0,
          max_turns INTEGER NOT NULL DEFAULT 12,
          state TEXT NOT NULL DEFAULT 'open',
          opened_at TEXT NOT NULL,
          closed_at TEXT
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS seen_envelopes (
          peer TEXT NOT NULL,
          envelope_id TEXT NOT NULL,
          seen_at TEXT NOT NULL,
          PRIMARY KEY (peer, envelope_id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS bindings (
          topic TEXT NOT NULL,
          principal_id TEXT NOT NULL,
          peer_scope TEXT NOT NULL,
          confidence INTEGER NOT NULL DEFAULT 0,
          confirmed INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          PRIMARY KEY (topic, principal_id, peer_scope)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS disclosures (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          peer TEXT NOT NULL,
          scope TEXT,
          kind TEXT NOT NULL,
          ref_id TEXT,
          summary TEXT NOT NULL,
          created_at TEXT NOT NULL
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS idx_disclosures_peer ON disclosures (peer, created_at)
      """,
      """
      CREATE TABLE IF NOT EXISTS outbound_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          peer TEXT NOT NULL,
          envelope_json TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'queued',
          attempts INTEGER NOT NULL DEFAULT 0,
          next_attempt_at TEXT NOT NULL,
          last_error TEXT,
          created_at TEXT NOT NULL,
          delivered_at TEXT
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS idx_outbound_queue_due ON outbound_queue (next_attempt_at)
          WHERE state = 'queued'
      """,
      """
      CREATE TABLE IF NOT EXISTS peer_delivery_alerts (
          peer TEXT PRIMARY KEY,
          alerted_at TEXT NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS circles (
          name TEXT NOT NULL,
          principal_id TEXT NOT NULL,
          added_at TEXT NOT NULL,
          PRIMARY KEY (name, principal_id)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS trust_signals (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          principal_id TEXT NOT NULL,
          topic TEXT NOT NULL,
          item TEXT NOT NULL,
          action TEXT NOT NULL,
          created_at TEXT NOT NULL
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS idx_trust_signals_principal
          ON trust_signals (principal_id, topic)
      """,
      """
      CREATE TABLE IF NOT EXISTS peer_llm_usage (
          month TEXT NOT NULL,
          principal_id TEXT NOT NULL,
          loops INTEGER NOT NULL DEFAULT 0,
          alerted INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (month, principal_id)
      )
      """
    ]
  end
end
