defmodule KbaseBot.Repo.Store do
  use GenServer

  @db_path "priv/repo.db"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def query(sql, params \\ []) do
    GenServer.call(__MODULE__, {:query, sql, params})
  end

  def execute(sql, params \\ []) do
    GenServer.call(__MODULE__, {:execute, sql, params})
  end

  # --- Server ---

  @impl true
  def init(_) do
    db_path = Path.join(Application.app_dir(:kbase_bot), @db_path)
    File.mkdir_p!(Path.dirname(db_path))

    {:ok, conn} = Exqlite.Sqlite3.open(db_path)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")

    KbaseBot.Repo.Migrations.run(conn)

    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call({:query, sql, params}, _from, %{conn: conn} = state) do
    result = do_query(conn, sql, params)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:execute, sql, params}, _from, %{conn: conn} = state) do
    result = do_execute(conn, sql, params)
    {:reply, result, state}
  end

  defp do_query(conn, sql, params) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- bind_params(conn, stmt, params) do
      rows = fetch_all(conn, stmt, [])
      Exqlite.Sqlite3.release(conn, stmt)
      {:ok, rows}
    end
  end

  defp do_execute(conn, sql, params) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- bind_params(conn, stmt, params) do
      result = Exqlite.Sqlite3.step(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)

      case result do
        :done -> :ok
        {:row, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp bind_params(_conn, _stmt, []), do: :ok

  defp bind_params(_conn, stmt, params) do
    Exqlite.Sqlite3.bind(stmt, params)
  end

  defp fetch_all(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
