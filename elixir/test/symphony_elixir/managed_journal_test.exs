defmodule SymphonyElixir.ManagedJournalTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Managed.Journal

  test "append syncs the latest versioned state across close and reopen" do
    path = Path.join(System.tmp_dir!(), "symphony-managed-journal-#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, handle, %{}} = Journal.open(path)
    state = %{version: 1, control_revision: 3, event_cursor: 4, paused: true}
    assert :ok = Journal.append(handle, state)
    assert :ok = Journal.close(handle)

    assert {:ok, reopened, ^state} = Journal.open(path)
    assert Journal.version() == 1
    assert :ok = Journal.close(reopened)
  end

  test "malformed persisted records fail visibly" do
    path = Path.join(System.tmp_dir!(), "symphony-managed-journal-#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm(path) end)

    name = String.to_atom("managed_journal_test_#{System.unique_integer([:positive])}")
    assert {:ok, handle, %{}} = Journal.open(path, name: name)
    assert :ok = :disk_log.log(name, %{version: 999, kind: :state, state: %{}})
    assert :ok = :disk_log.sync(name)
    assert :ok = Journal.close(handle)

    assert {:error, {:managed_journal_read_failed, {:managed_journal_schema_mismatch, 999}}} = Journal.open(path, name: name)
  end
end
