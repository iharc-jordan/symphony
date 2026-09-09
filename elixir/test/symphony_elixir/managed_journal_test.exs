defmodule SymphonyElixir.ManagedJournalTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Managed.Journal

  test "append syncs the latest versioned state across close and reopen" do
    path = journal_path("roundtrip")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    state = %{version: 1, control_revision: 3, event_cursor: 4, paused: true}
    assert :ok = Journal.append(handle, state)
    assert :ok = Journal.close(handle)

    assert {:ok, reopened, ^state} = Journal.open(path)
    assert Journal.version() == 1
    assert :ok = Journal.close(reopened)
  end

  test "append reports the disk log error when its handle is closed" do
    path = journal_path("append-error")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    assert :ok = Journal.close(handle)
    assert {:error, :no_such_log} = Journal.append(handle, %{state: :unavailable})
  end

  test "loads a log repaired after an interrupted writer" do
    path = journal_path("repaired")
    name = journal_name("repaired")
    on_exit(fn -> File.rm(path) end)
    create_unclosed_log!(path, name, %{version: 1, kind: :state, state: %{recovered: true}})

    assert {:ok, handle, %{recovered: true}} = Journal.open(path, name: name)
    assert :ok = Journal.close(handle)
  end

  test "rejects repaired logs containing non-term bytes" do
    path = journal_path("repaired-corrupt")
    name = journal_name("repaired-corrupt")
    on_exit(fn -> File.rm(path) end)
    create_unclosed_log!(path, name, %{version: 1, kind: :state, state: %{recovered: true}})
    append_bytes!(path, :binary.copy(<<0>>, 7))

    assert {:error, {:managed_journal_corrupt, 7}} = Journal.open(path, name: name)
  end

  test "reports malformed and schema-mismatched persisted records" do
    schema_path = journal_path("schema-mismatch")
    schema_name = journal_name("schema-mismatch")
    malformed_path = journal_path("malformed")
    malformed_name = journal_name("malformed")
    on_exit(fn -> File.rm(schema_path) end)
    on_exit(fn -> File.rm(malformed_path) end)

    assert {:ok, schema_handle, %{}} = Journal.open(schema_path, name: schema_name)
    assert :ok = :disk_log.log(schema_name, %{version: 999, kind: :state, state: %{}})
    assert :ok = :disk_log.sync(schema_name)
    assert :ok = Journal.close(schema_handle)

    assert {:error, {:managed_journal_read_failed, {:managed_journal_schema_mismatch, 999}}} =
             Journal.open(schema_path, name: schema_name)

    assert {:ok, malformed_handle, %{}} = Journal.open(malformed_path, name: malformed_name)
    assert :ok = :disk_log.log(malformed_name, %{unexpected: :record})
    assert :ok = :disk_log.sync(malformed_name)
    assert :ok = Journal.close(malformed_handle)

    assert {:error, {:managed_journal_read_failed, :managed_journal_malformed_record}} =
             Journal.open(malformed_path, name: malformed_name)
  end

  test "reports corruption found while reading an otherwise openable log" do
    path = journal_path("chunk-corrupt")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    assert :ok = Journal.append(handle, %{state: :valid})
    assert :ok = Journal.close(handle)
    append_bytes!(path, :binary.copy(<<0>>, 32))

    assert {:error, {:managed_journal_read_failed, {:corrupt_log_file, _path}}} =
             Journal.open(path)
  end

  test "loads the latest state after reading multiple disk log chunks" do
    path = journal_path("multi-chunk")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)

    for index <- 1..100 do
      assert :ok = Journal.append(handle, %{index: index, payload: String.duplicate("x", 1_000)})
    end

    assert :ok = Journal.close(handle)
    assert {:ok, reopened, %{index: 100, payload: payload}} = Journal.open(path)
    assert byte_size(payload) == 1_000
    assert :ok = Journal.close(reopened)
  end

  test "reports invalid log files and parent directory failures" do
    path = journal_path("not-a-log")
    parent = journal_path("parent-file")
    child_path = Path.join(parent, "journal.log")
    on_exit(fn -> File.rm(path) end)
    on_exit(fn -> File.rm(parent) end)

    File.write!(path, "not a disk log")

    assert {:error, {:managed_journal_open_failed, {:not_a_log_file, _}}} = Journal.open(path)

    File.write!(parent, "a file cannot be a directory")
    assert {:error, {:managed_journal_parent_failed, :enotdir}} = Journal.open(child_path)
  end

  defp journal_path(prefix) do
    Path.join(System.tmp_dir!(), "symphony-managed-journal-#{prefix}-#{System.unique_integer([:positive])}.log")
  end

  defp journal_name(prefix) do
    String.to_atom("managed_journal_#{prefix}_#{System.unique_integer([:positive])}")
  end

  defp append_bytes!(path, bytes) do
    {:ok, file} = File.open(path, [:append, :binary])
    :ok = IO.binwrite(file, bytes)
    :ok = File.close(file)
  end

  defp create_unclosed_log!(path, name, record) do
    script = Path.join(System.tmp_dir!(), "managed-journal-crasher-#{System.unique_integer([:positive])}.exs")

    File.write!(
      script,
      """
      path = hd(System.argv())
      name = String.to_atom(hd(tl(System.argv())))
      record = :erlang.binary_to_term(Base.decode64!(hd(tl(tl(System.argv())))))
      {:ok, ^name} = :disk_log.open(name: name, file: String.to_charlist(path), type: :halt)
      :ok = :disk_log.log(name, record)
      :ok = :disk_log.sync(name)
      :erlang.halt()
      """
    )

    encoded = record |> :erlang.term_to_binary() |> Base.encode64()
    executable = System.find_executable("elixir") || raise "elixir executable is required"
    {_output, 0} = System.cmd(executable, [script, path, Atom.to_string(name), encoded], stderr_to_stdout: true)
    File.rm!(script)
  end
end
