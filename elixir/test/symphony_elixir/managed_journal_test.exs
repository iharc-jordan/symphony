defmodule SymphonyElixir.ManagedJournalTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Managed.Journal

  test "append syncs the latest versioned state across close and reopen" do
    path = journal_path("roundtrip")
    on_exit(fn -> cleanup(path) end)

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
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    assert :ok = Journal.close(handle)
    assert {:error, :no_such_log} = Journal.append(handle, %{state: :unavailable})
  end

  test "loads a log repaired after an interrupted writer" do
    path = journal_path("repaired")
    name = journal_name("repaired")
    on_exit(fn -> cleanup(path) end)
    create_unclosed_log!(path, name, %{version: 1, kind: :state, state: %{recovered: true}})

    assert {:ok, handle, %{recovered: true}} = Journal.open(path, name: name)
    assert :ok = Journal.close(handle)
  end

  test "rejects repaired logs containing non-term bytes" do
    path = journal_path("repaired-corrupt")
    name = journal_name("repaired-corrupt")
    on_exit(fn -> cleanup(path) end)
    create_unclosed_log!(path, name, %{version: 1, kind: :state, state: %{recovered: true}})
    append_bytes!(path, :binary.copy(<<0>>, 7))

    assert {:error, {:managed_journal_corrupt, 7}} = Journal.open(path, name: name)
  end

  test "accepts a repaired WAL tail when a verified checkpoint anchors recovery" do
    path = journal_path("checkpoint-repaired")
    name = journal_name("checkpoint-repaired")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path, name: name)
    assert :ok = Journal.append(handle, %{revision: 1})
    assert :ok = Journal.close(handle)

    create_unclosed_log!(path, name, state_record(%{revision: 2}))
    append_bytes!(path, :binary.copy(<<0>>, 7))

    assert {:ok, reopened, %{revision: 2}} = Journal.open(path, name: name)
    assert :eof = :disk_log.chunk(name, :start)
    assert :ok = Journal.close(reopened)
  end

  test "reports malformed and schema-mismatched persisted records" do
    schema_path = journal_path("schema-mismatch")
    schema_name = journal_name("schema-mismatch")
    malformed_path = journal_path("malformed")
    malformed_name = journal_name("malformed")
    on_exit(fn -> cleanup(schema_path) end)
    on_exit(fn -> cleanup(malformed_path) end)

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

  test "fails closed on a corrupt checkpoint without consuming the valid WAL" do
    path = journal_path("checkpoint-corrupt")
    name = journal_name("checkpoint-corrupt")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path, name: name)
    assert :ok = Journal.append(handle, %{revision: 1})
    assert :ok = Journal.close(handle)

    append_wal_record!(path, name, state_record(%{revision: 2}))
    File.write!(checkpoint_path(path), "not an external term")
    wal_bytes = File.stat!(path).size

    assert {:error, {:managed_journal_checkpoint_invalid, :managed_journal_checkpoint_corrupt}} = Journal.open(path, name: name)

    assert File.stat!(path).size == wal_bytes

    File.rm!(checkpoint_path(path))
    assert {:ok, recovered, %{revision: 2}} = Journal.open(path, name: name)
    assert :ok = Journal.close(recovered)
  end

  test "fails closed on a checkpoint schema mismatch" do
    path = journal_path("checkpoint-schema")
    name = journal_name("checkpoint-schema")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path, name: name)
    assert :ok = Journal.close(handle)
    File.write!(checkpoint_path(path), :erlang.term_to_binary(%{version: 999, kind: :state, state: %{}}))

    assert {:error, {:managed_journal_checkpoint_invalid, {:managed_journal_schema_mismatch, 999}}} = Journal.open(path, name: name)
  end

  test "detects content corruption in an otherwise valid checkpoint envelope" do
    path = journal_path("checkpoint-content-corrupt")
    name = journal_name("checkpoint-content-corrupt")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path, name: name)
    assert :ok = Journal.append(handle, %{revision: 1, ownership: %{owner: "pm-1"}})
    assert :ok = Journal.close(handle)

    checkpoint = checkpoint_path(path)
    envelope = checkpoint |> File.read!() |> :erlang.binary_to_term([:safe])
    <<first, rest::binary>> = envelope.payload
    corrupted_payload = <<:erlang.bxor(first, 1), rest::binary>>
    File.write!(checkpoint, :erlang.term_to_binary(%{envelope | payload: corrupted_payload}))

    assert {:error, {:managed_journal_checkpoint_invalid, :managed_journal_checkpoint_checksum_mismatch}} =
             Journal.open(path, name: name)
  end

  test "a fresh BEAM restores valid state atoms that are not already loaded" do
    path = journal_path("fresh-beam")
    on_exit(fn -> cleanup(path) end)
    dynamic_atom = String.to_atom("managed_restart_atom_#{System.unique_integer([:positive])}")
    state = %{dynamic_atom => dynamic_atom, version: 2}

    assert {:ok, handle, %{}} = Journal.open(path)
    assert :ok = Journal.append(handle, state)
    assert :ok = Journal.close(handle)

    assert {:ok, ^state} = reopen_in_fresh_beam(path)
  end

  test "many large updates keep total bytes bounded and restart returns the newest state" do
    path = journal_path("bounded")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    payload = :crypto.strong_rand_bytes(64_000)

    sizes =
      for index <- 1..40 do
        assert :ok = Journal.append(handle, %{index: index, payload: payload})
        File.stat!(path).size + File.stat!(checkpoint_path(path)).size
      end

    assert Enum.max(sizes) - Enum.min(sizes) < 1_024
    assert Enum.max(sizes) < byte_size(payload) + 4_096
    assert :eof = :disk_log.chunk(handle.name, :start)
    assert :ok = Journal.close(handle)
    assert {:ok, reopened, %{index: 40, payload: ^payload}} = Journal.open(path)
    assert :ok = Journal.close(reopened)
  end

  test "migrates a legacy append-only log after preserving its exact latest state" do
    path = journal_path("legacy")
    name = journal_name("legacy")
    on_exit(fn -> cleanup(path) end)

    latest = %{
      assignments: %{"a-1" => %{revision: 4, reports: %{"r-1" => %{kind: "result"}}}},
      ownership: %{owner: "pm-1"},
      control_revision: 9,
      event_cursor: 12
    }

    append_wal_records!(path, name, [state_record(%{control_revision: 8}), state_record(latest)])

    assert {:ok, migrated, ^latest} = Journal.open(path, name: name)
    assert checkpoint_state(path) === latest
    assert :eof = :disk_log.chunk(name, :start)
    assert :ok = Journal.close(migrated)
  end

  test "replays a newer WAL record after a checkpoint crash window and compacts it" do
    path = journal_path("crash-window")
    name = journal_name("crash-window")
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path, name: name)
    assert :ok = Journal.append(handle, %{revision: 1})
    assert :ok = Journal.close(handle)

    append_wal_record!(path, name, state_record(%{revision: 2, reports: %{latest: true}}))

    assert {:ok, recovered, %{revision: 2, reports: %{latest: true}} = latest} =
             Journal.open(path, name: name)

    assert checkpoint_state(path) === latest
    assert :eof = :disk_log.chunk(name, :start)
    assert :ok = Journal.close(recovered)
  end

  test "checkpoint replacement failure leaves the synced WAL recoverable" do
    path = journal_path("checkpoint-failure")
    name = journal_name("checkpoint-failure")
    checkpoint = checkpoint_path(path)
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path, name: name)
    File.rm!(checkpoint)
    File.mkdir!(checkpoint)

    latest = %{revision: 5, reports: %{context: "retained"}}

    assert {:error, {:managed_journal_checkpoint_rename_failed, :eisdir}} =
             Journal.append(handle, latest)

    assert {_continuation, [record]} = :disk_log.chunk(name, :start)
    assert record == state_record(latest)
    assert :ok = Journal.close(handle)

    File.rmdir!(checkpoint)
    assert {:ok, recovered, ^latest} = Journal.open(path, name: name)
    assert checkpoint_state(path) === latest
    assert :ok = Journal.close(recovered)
  end

  test "repeated checkpoint failures retain only the newest WAL state" do
    path = journal_path("checkpoint-repeated-failure")
    name = journal_name("checkpoint-repeated-failure")
    checkpoint = checkpoint_path(path)
    on_exit(fn -> cleanup(path) end)

    assert {:ok, handle, %{}} = Journal.open(path, name: name)
    File.rm!(checkpoint)
    File.mkdir!(checkpoint)
    payload = :crypto.strong_rand_bytes(64_000)

    for revision <- 1..40 do
      assert {:error, {:managed_journal_checkpoint_rename_failed, :eisdir}} =
               Journal.append(handle, %{revision: revision, payload: payload})
    end

    assert File.stat!(path).size < byte_size(payload) + 4_096
    assert {_continuation, [record]} = :disk_log.chunk(name, :start)
    assert record == state_record(%{revision: 40, payload: payload})
    assert :ok = Journal.close(handle)

    File.rmdir!(checkpoint)
    assert {:ok, recovered, %{revision: 40, payload: ^payload}} = Journal.open(path, name: name)
    assert :ok = Journal.close(recovered)
  end

  test "a failed next checkpoint preserves the last acknowledged checkpoint and newer WAL" do
    path = journal_path("checkpoint-acknowledged")
    name = journal_name("checkpoint-acknowledged")
    blocked_parent = path <> ".blocked"
    on_exit(fn -> cleanup(path) end)
    on_exit(fn -> File.rm(blocked_parent) end)

    acknowledged = %{revision: 1, reports: %{accepted: true}}
    newer = %{revision: 2, reports: %{accepted: true, published: true}}
    assert {:ok, handle, %{}} = Journal.open(path, name: name)
    assert :ok = Journal.append(handle, acknowledged)
    File.write!(blocked_parent, "not a directory")
    broken_handle = %{handle | checkpoint_path: Path.join(blocked_parent, "checkpoint")}

    assert {:error, {:managed_journal_checkpoint_write_failed, :enotdir}} =
             Journal.append(broken_handle, newer)

    assert checkpoint_state(path) === acknowledged
    assert {_continuation, [record]} = :disk_log.chunk(name, :start)
    assert record == state_record(newer)
    assert :ok = Journal.close(handle)

    assert {:ok, recovered, ^newer} = Journal.open(path, name: name)
    assert :ok = Journal.close(recovered)
  end

  test "reports invalid log files and parent directory failures" do
    path = journal_path("not-a-log")
    parent = journal_path("parent-file")
    child_path = Path.join(parent, "journal.log")
    on_exit(fn -> cleanup(path) end)
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

  defp append_wal_record!(path, name, record),
    do: append_wal_records!(path, name, [record])

  defp append_wal_records!(path, name, records) do
    {:ok, ^name} = :disk_log.open(name: name, file: String.to_charlist(path), type: :halt)
    Enum.each(records, fn record -> :ok = :disk_log.log(name, record) end)
    :ok = :disk_log.sync(name)
    :ok = :disk_log.close(name)
  end

  defp state_record(state), do: %{version: Journal.version(), kind: :state, state: state}

  defp checkpoint_state(path) do
    %{version: 1, kind: :checkpoint, checksum: checksum, payload: payload} =
      path
      |> checkpoint_path()
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    assert :crypto.hash(:sha256, payload) == checksum
    %{version: 1, kind: :state, state: state} = :erlang.binary_to_term(payload, [:safe])
    state
  end

  defp checkpoint_path(path), do: path <> ".checkpoint"

  defp reopen_in_fresh_beam(path) do
    script = Path.join(System.tmp_dir!(), "managed-journal-restart-#{System.unique_integer([:positive])}.exs")
    result_path = script <> ".result"
    journal_ebin = Journal |> :code.which() |> List.to_string() |> Path.dirname()

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
      executable = System.find_executable("elixir") || raise "elixir executable is required"

      {_output, 0} =
        System.cmd(executable, ["-pa", journal_ebin, script, path, result_path], stderr_to_stdout: true)

      result_path |> File.read!() |> :erlang.binary_to_term([:safe])
    after
      File.rm(script)
      File.rm(result_path)
    end
  end

  defp cleanup(path) do
    File.rm_rf(path)
    File.rm_rf(checkpoint_path(path))
    Enum.each(Path.wildcard(checkpoint_path(path) <> ".tmp-*"), &File.rm_rf/1)
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
