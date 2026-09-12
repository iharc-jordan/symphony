defmodule SymphonyElixir.Managed.Journal do
  @moduledoc """
  Durable single-process SQLite snapshot storage for managed orchestration.

  A managed runtime owns one SQLite connection for its entire lifetime. The
  database has one row containing the latest versioned state map; bounded
  events remain part of that map rather than becoming a second store.
  """

  alias Exqlite.Sqlite3

  @version 1
  @snapshot_table "managed_snapshot"

  @type handle :: %{conn: reference(), path: Path.t()}

  @spec open(Path.t(), keyword()) :: {:ok, handle(), map()} | {:error, term()}
  def open(path, _opts \\ []) when is_binary(path) do
    expanded = Path.expand(path)

    with :ok <- ensure_parent(expanded),
         {:ok, conn} <- open_connection(expanded) do
      initialize_and_load(conn, expanded)
    end
  end

  defp initialize_and_load(conn, path) do
    with :ok <- initialize_connection(conn),
         {:ok, state} <- load_snapshot(conn) do
      {:ok, %{conn: conn, path: path}, state}
    else
      {:error, reason} -> close_after_open_failure(conn, reason)
    end
  end

  @spec append(handle(), map()) :: :ok | {:error, term()}
  def append(%{conn: conn}, state) when is_map(state) do
    state
    |> :erlang.term_to_binary()
    |> write_snapshot(conn)
  rescue
    error -> {:error, {:managed_journal_write_failed, exception_reason(error)}}
  catch
    kind, reason -> {:error, {:managed_journal_write_failed, {kind, reason}}}
  end

  def append(_handle, _state), do: {:error, :managed_journal_handle_invalid}

  @spec close(handle()) :: :ok
  def close(%{conn: conn}) do
    _ = Sqlite3.close(conn)
    :ok
  end

  def close(_handle), do: :ok

  @spec version() :: pos_integer()
  def version, do: @version

  defp open_connection(path) do
    case Sqlite3.open(path, mode: [:readwrite, :create]) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, open_error(reason)}
    end
  rescue
    error -> {:error, {:managed_journal_open_failed, exception_reason(error)}}
  catch
    kind, reason -> {:error, {:managed_journal_open_failed, {kind, reason}}}
  end

  # Locking mode is intentionally the first SQLite command after opening the
  # connection. The exclusive transaction proves that this runtime has the
  # singleton before it reads state or can dispatch an external effect.
  defp initialize_connection(conn) do
    with :ok <- Sqlite3.set_busy_timeout(conn, 0),
         :ok <- sql_execute(conn, "PRAGMA locking_mode = EXCLUSIVE"),
         :ok <- acquire_singleton(conn),
         :ok <- sql_execute(conn, "PRAGMA journal_mode = WAL"),
         :ok <- sql_execute(conn, "PRAGMA synchronous = FULL"),
         :ok <- sql_execute(conn, "PRAGMA wal_autocheckpoint = 1"),
         :ok <- sql_execute(conn, snapshot_table_statement()) do
      :ok
    else
      {:error, reason} -> {:error, initialize_error(reason)}
    end
  end

  defp acquire_singleton(conn) do
    with :ok <- sql_execute(conn, "BEGIN EXCLUSIVE"),
         :ok <- sql_execute(conn, "COMMIT") do
      :ok
    else
      {:error, reason} ->
        _ = sql_execute(conn, "ROLLBACK")
        {:error, singleton_error(reason)}
    end
  end

  defp snapshot_table_statement do
    """
    CREATE TABLE IF NOT EXISTS #{@snapshot_table} (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      version INTEGER NOT NULL,
      state BLOB NOT NULL
    )
    """
  end

  defp load_snapshot(conn) do
    case query(conn, "SELECT id, version, state FROM #{@snapshot_table} ORDER BY id", []) do
      {:ok, rows} ->
        decode_snapshot_rows(rows)

      {:error, reason} ->
        if busy?(reason),
          do: {:error, :managed_runtime_already_running},
          else: {:error, {:managed_journal_snapshot_read_failed, reason}}
    end
  end

  defp decode_snapshot_rows([]), do: {:ok, %{}}

  defp decode_snapshot_rows([[1, version, payload]]) when version == @version and is_binary(payload),
    do: decode_snapshot(payload)

  defp decode_snapshot_rows([[1, version, _payload]]),
    do: {:error, {:managed_journal_schema_mismatch, version}}

  defp decode_snapshot_rows(_rows), do: {:error, :managed_journal_snapshot_malformed}

  # This is a trusted local payload boundary. [:used] detects trailing input
  # while preserving fresh-BEAM atom restoration; [:safe] would reject valid
  # locally persisted state atoms that the new BEAM has not yet seen.
  defp decode_snapshot(payload) do
    case :erlang.binary_to_term(payload, [:used]) do
      {state, used} when used == byte_size(payload) and is_map(state) -> {:ok, state}
      {_state, used} when used != byte_size(payload) -> {:error, :managed_journal_snapshot_trailing_bytes}
      {_state, _used} -> {:error, :managed_journal_snapshot_malformed}
    end
  rescue
    ArgumentError -> {:error, :managed_journal_snapshot_corrupt}
  catch
    :error, :badarg -> {:error, :managed_journal_snapshot_corrupt}
  end

  defp write_snapshot(payload, conn) do
    with :ok <- sql_execute(conn, "BEGIN IMMEDIATE"),
         :ok <- upsert_snapshot(conn, payload),
         :ok <- commit_snapshot(conn) do
      :ok
    else
      {:error, {:managed_journal_commit_failed, _reason}} = error ->
        _ = sql_execute(conn, "ROLLBACK")
        error

      {:error, reason} ->
        _ = sql_execute(conn, "ROLLBACK")
        {:error, {:managed_journal_write_failed, reason}}
    end
  end

  defp upsert_snapshot(conn, payload) do
    statement = """
    INSERT INTO #{@snapshot_table} (id, version, state) VALUES (1, ?1, ?2)
    ON CONFLICT(id) DO UPDATE SET version = excluded.version, state = excluded.state
    """

    case step(conn, statement, [@version, {:blob, payload}]) do
      :done -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:managed_journal_snapshot_write_unexpected, other}}
    end
  end

  # A caller must never treat a failed COMMIT as acknowledged. In particular,
  # the orchestrator leaves in-memory state unchanged and dispatches no
  # follow-on effect when this returns an error.
  defp commit_snapshot(conn) do
    case sql_execute(conn, "COMMIT") do
      :ok -> :ok
      {:error, reason} -> {:error, {:managed_journal_commit_failed, reason}}
    end
  end

  defp query(conn, statement, params) do
    with_statement(conn, statement, params, &Sqlite3.fetch_all(conn, &1))
  end

  defp step(conn, statement, params) do
    with_statement(conn, statement, params, &Sqlite3.step(conn, &1))
  end

  defp with_statement(conn, statement, params, callback) do
    case Sqlite3.prepare(conn, statement) do
      {:ok, prepared} ->
        try do
          with :ok <- Sqlite3.bind(prepared, params) do
            callback.(prepared)
          end
        rescue
          error -> {:error, exception_reason(error)}
        catch
          kind, reason -> {:error, {kind, reason}}
        after
          _ = Sqlite3.release(conn, prepared)
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, exception_reason(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp sql_execute(conn, statement) do
    case Sqlite3.execute(conn, statement) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, exception_reason(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp close_after_open_failure(conn, reason) do
    _ = Sqlite3.close(conn)
    {:error, reason}
  end

  defp open_error(reason) do
    if busy?(reason), do: :managed_runtime_already_running, else: {:managed_journal_open_failed, reason}
  end

  defp singleton_error(reason) do
    if busy?(reason), do: :managed_runtime_already_running, else: {:managed_journal_singleton_failed, reason}
  end

  defp initialize_error(:managed_runtime_already_running), do: :managed_runtime_already_running

  defp initialize_error(reason) do
    if busy?(reason), do: :managed_runtime_already_running, else: {:managed_journal_initialize_failed, reason}
  end

  defp busy?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> then(&(String.contains?(&1, "busy") or String.contains?(&1, "locked")))
  end

  defp ensure_parent(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:managed_journal_parent_failed, reason}}
    end
  end

  defp exception_reason(error), do: Exception.message(error)
end
