defmodule SymphonyElixir.ManagedJournalTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias SymphonyElixir.Managed.Journal

  test "stores exactly one versioned snapshot and restores the exact newest state" do
    path = journal_path("roundtrip")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    first = %{version: 1, control_revision: 3, event_cursor: 4, paused: true}
    newest = first |> Map.put(:control_revision, 4) |> Map.put(:events, [%{cursor: 4, operation: :updated}])

    assert :ok = Journal.append(handle, first)
    assert :ok = Journal.append(handle, newest)
    assert [[1, 1]] = query_rows!(handle.conn, "SELECT id, version FROM managed_snapshot")
    assert :ok = Journal.close(handle)

    assert {:ok, reopened, ^newest} = Journal.open(path)
    assert Journal.version() == 1
    assert :ok = Journal.close(reopened)
  end

  test "a second BEAM cannot acquire the exclusive managed runtime lock" do
    path = journal_path("singleton")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    assert {:error, :managed_runtime_already_running} = open_in_fresh_beam(path)
    assert :ok = Journal.close(handle)
    assert {:ok, reopened, %{}} = Journal.open(path)
    assert :ok = Journal.close(reopened)
  end

  test "a process crash after a committed snapshot restores the acknowledged state" do
    path = journal_path("crash")
    on_exit(fn -> cleanup(path) end)

    state = %{version: 1, control_revision: 8, events: [%{operation: :durable_before_crash}]}
    crash_after_append!(path, state)

    assert {:ok, handle, ^state} = Journal.open(path)
    assert :ok = Journal.close(handle)
  end

  test "a fresh BEAM crash with an uncommitted replacement preserves the prior snapshot" do
    path = journal_path("uncommitted-crash")
    on_exit(fn -> cleanup(path) end)

    acknowledged = %{version: 1, revision: 8, events: [%{operation: :committed}]}
    replacement = %{version: 1, revision: 9, events: [%{operation: :must_not_commit}]}

    assert {:ok, handle, %{}} = Journal.open(path)
    assert :ok = Journal.append(handle, acknowledged)
    assert :ok = Journal.close(handle)

    assert 17 = crash_with_uncommitted_replacement!(path, replacement)

    assert {:ok, reopened, ^acknowledged} = Journal.open(path)
    assert :ok = Journal.close(reopened)
  end

  test "rejects corrupt snapshot payloads and trailing term bytes" do
    path = journal_path("corrupt")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    assert :ok = Journal.append(handle, %{version: 1, revision: 1})
    assert :ok = Journal.close(handle)

    set_snapshot!(path, 1, <<0>>)
    assert {:error, :managed_journal_snapshot_corrupt} = Journal.open(path)

    set_snapshot!(path, 1, :erlang.term_to_binary(%{version: 1, revision: 2}) <> <<0>>)
    assert {:error, :managed_journal_snapshot_trailing_bytes} = Journal.open(path)
  end

  test "rejects an unsupported persisted snapshot version" do
    path = journal_path("version")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    assert :ok = Journal.append(handle, %{version: 1, revision: 1})
    assert :ok = Journal.close(handle)

    set_snapshot!(path, 999, :erlang.term_to_binary(%{version: 1, revision: 1}))
    assert {:error, {:managed_journal_schema_mismatch, 999}} = Journal.open(path)
  end

  test "SQLITE_FULL is not acknowledged and does not replace the durable snapshot" do
    path = journal_path("sqlite-full")
    on_exit(fn -> cleanup(path) end)

    acknowledged = %{version: 1, revision: 1, reports: %{accepted: true}}
    assert {:ok, handle, %{}} = Journal.open(path)
    assert :ok = Journal.append(handle, acknowledged)

    assert [[page_count]] = query_rows!(handle.conn, "PRAGMA page_count")
    assert :ok = Sqlite3.execute(handle.conn, "PRAGMA max_page_count = #{page_count}")

    replacement = %{
      version: 1,
      revision: 2,
      payload: :crypto.strong_rand_bytes(max(page_count * 8_192, 1_048_576))
    }

    assert {:error, {:managed_journal_write_failed, _reason}} =
             Journal.append(handle, replacement)

    assert :ok = Journal.close(handle)

    assert {:ok, reopened, ^acknowledged} = Journal.open(path)
    assert :ok = Journal.close(reopened)
  end

  test "large replacements remain bounded and retain only the latest snapshot" do
    path = journal_path("bounded")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    payload = :crypto.strong_rand_bytes(64_000)

    sizes =
      for revision <- 1..40 do
        assert :ok = Journal.append(handle, %{version: 1, revision: revision, payload: payload})
        database_footprint(path)
      end

    assert Enum.max(sizes) - Enum.min(sizes) < 128_000
    assert Enum.max(sizes) < 256_000
    assert [[1]] = query_rows!(handle.conn, "SELECT COUNT(*) FROM managed_snapshot")
    assert :ok = Journal.close(handle)

    assert {:ok, reopened, %{revision: 40, payload: ^payload}} = Journal.open(path)
    assert :ok = Journal.close(reopened)
  end

  test "a fresh BEAM restores trusted state atoms using exact used-byte decoding" do
    path = journal_path("fresh-beam")
    on_exit(fn -> cleanup(path) end)

    dynamic_atom = String.to_atom("managed_restart_atom_#{System.unique_integer([:positive])}")
    state = %{dynamic_atom => dynamic_atom, version: 2}

    assert {:ok, handle, %{}} = Journal.open(path)
    assert :ok = Journal.append(handle, state)
    assert :ok = Journal.close(handle)

    assert {:ok, ^state} = open_in_fresh_beam(path)
  end

  defp set_snapshot!(path, version, payload) do
    {:ok, conn} = Sqlite3.open(path, mode: [:readwrite])

    try do
      statement = "UPDATE managed_snapshot SET version = ?1, state = ?2 WHERE id = 1"
      :done = step!(conn, statement, [version, {:blob, payload}])
    after
      :ok = Sqlite3.close(conn)
    end
  end

  defp query_rows!(conn, sql) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(statement, [])
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      rows
    after
      :ok = Sqlite3.release(conn, statement)
    end
  end

  defp step!(conn, sql, params) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      Sqlite3.step(conn, statement)
    after
      :ok = Sqlite3.release(conn, statement)
    end
  end

  defp open_in_fresh_beam(path) do
    script = Path.join(System.tmp_dir!(), "managed-journal-open-#{System.unique_integer([:positive])}.exs")
    result_path = script <> ".result"

    File.write!(
      script,
      """
      [path, result_path] = System.argv()
      result =
        case SymphonyElixir.Managed.Journal.open(path) do
          {:ok, handle, state} ->
            :ok = SymphonyElixir.Managed.Journal.close(handle)
            {:ok, state}

          error ->
            error
        end

      File.write!(result_path, :erlang.term_to_binary(result))
      """
    )

    try do
      {_output, 0} = run_fresh_beam(beam_args(script, path, result_path))
      result_path |> File.read!() |> :erlang.binary_to_term([:used]) |> elem(0)
    after
      File.rm(script)
      File.rm(result_path)
    end
  end

  defp crash_after_append!(path, state) do
    script = Path.join(System.tmp_dir!(), "managed-journal-crash-#{System.unique_integer([:positive])}.exs")
    encoded = state |> :erlang.term_to_binary() |> Base.encode64()

    File.write!(
      script,
      """
      [path, encoded] = System.argv()
      state = encoded |> Base.decode64!() |> :erlang.binary_to_term([:used]) |> elem(0)
      {:ok, handle, %{}} = SymphonyElixir.Managed.Journal.open(path)
      :ok = SymphonyElixir.Managed.Journal.append(handle, state)
      :erlang.halt(0)
      """
    )

    try do
      {_output, 0} = run_fresh_beam(beam_args(script, path, encoded))
    after
      File.rm(script)
    end
  end

  defp crash_with_uncommitted_replacement!(path, state) do
    script = Path.join(System.tmp_dir!(), "managed-journal-uncommitted-#{System.unique_integer([:positive])}.exs")
    encoded = state |> :erlang.term_to_binary() |> Base.encode64()

    File.write!(
      script,
      """
      [path, encoded] = System.argv()
      state = encoded |> Base.decode64!() |> :erlang.binary_to_term([:used]) |> elem(0)
      payload = :erlang.term_to_binary(state)
      {:ok, conn} = Exqlite.Sqlite3.open(path, mode: [:readwrite])
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = WAL")
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous = FULL")
      :ok = Exqlite.Sqlite3.execute(conn, "BEGIN IMMEDIATE")
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "UPDATE managed_snapshot SET state = ?1 WHERE id = 1")
      :ok = Exqlite.Sqlite3.bind(statement, [{:blob, payload}])
      :done = Exqlite.Sqlite3.step(conn, statement)
      :erlang.halt(17)
      """
    )

    try do
      {_output, status} = run_fresh_beam(beam_args(script, path, encoded))
      status
    after
      File.rm(script)
    end
  end

  defp beam_args(script, first, second) do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&["-pa", &1])
    |> Kernel.++([script, first, second])
  end

  defp run_fresh_beam(args) do
    {executable, command_args} = fresh_beam_command(args)
    System.cmd(executable, command_args, stderr_to_stdout: true)
  end

  defp fresh_beam_command(args) do
    case :os.type() do
      {:win32, _} ->
        elixir = System.find_executable("elixir.bat") || raise "elixir executable is required"
        elixir_root = elixir |> Path.dirname() |> Path.join("../lib") |> Path.expand()
        elixir_ebin = Path.join([elixir_root, "elixir", "ebin"])
        erl = System.find_executable("erl.exe") || raise "erl executable is required"

        {erl,
         ["-noshell", "-elixir_root", elixir_root, "-pa", elixir_ebin, "-s", "elixir", "start_cli", "-extra"] ++
           args}

      _ ->
        {System.find_executable("elixir") || raise("elixir executable is required"), args}
    end
  end

  defp database_footprint(path) do
    [path, path <> "-wal", path <> "-shm"]
    |> Enum.map(fn file -> if File.exists?(file), do: File.stat!(file).size, else: 0 end)
    |> Enum.sum()
  end

  defp journal_path(prefix) do
    Path.join(System.tmp_dir!(), "symphony-managed-journal-#{prefix}-#{System.unique_integer([:positive])}.sqlite")
  end

  defp cleanup(path) do
    Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm_rf/1)
  end
end
