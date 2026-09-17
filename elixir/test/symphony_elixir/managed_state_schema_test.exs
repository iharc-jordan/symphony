defmodule SymphonyElixir.ManagedStateSchemaTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.{Journal, Rules}

  test "starts from the current managed-state schema without rewriting its journal record" do
    path = store_path("v2")
    state = terminal_state()
    configure_managed_journal!(path)
    assert SymphonyElixir.PathSafety.same_path?(Config.managed_store_path(), path)

    assert {:ok, journal, %{}} = Journal.open(path)
    assert :ok = Journal.append(journal, state)
    assert :ok = Journal.close(journal)

    orchestrator = unique_name("v2")
    assert {:ok, pid} = Orchestrator.start_link(name: orchestrator)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(path)
      File.rm(path <> ".checkpoint")
    end)

    loaded = :sys.get_state(pid).managed.data
    assert loaded.version == 2
    assert loaded.control_revision == state.control_revision
    assert loaded.assignments == state.assignments
    assert loaded.requests == state.requests

    :ok = GenServer.stop(pid)
    assert {:ok, reopened, ^state} = Journal.open(path)
    assert :ok = Journal.close(reopened)
  end

  test "rejects managed-state version one without appending a replacement record" do
    path = store_path("v1")
    state = %{version: 1, control_revision: 4, assignments: %{"old" => %{phase: :accepted}}}
    configure_managed_journal!(path)
    assert SymphonyElixir.PathSafety.same_path?(Config.managed_store_path(), path)

    assert {:ok, journal, %{}} = Journal.open(path)
    assert :ok = Journal.append(journal, state)
    assert :ok = Journal.close(journal)

    trap_exit? = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, trap_exit?) end)

    assert {:error, :managed_journal_schema_mismatch} = Orchestrator.start_link(name: unique_name("v1"))

    assert {:ok, reopened, ^state} = Journal.open(path)
    assert :ok = Journal.close(reopened)
    File.rm(path)
    File.rm(path <> ".checkpoint")
  end

  defp terminal_state do
    Rules.new(
      control_revision: 7,
      event_cursor: 11,
      projects: %{"PVT_test" => %{project_id: "PVT_test", revision: 1, dispatch_paused: false}},
      principals: %{"pm" => %{principal_id: "pm", role: :pm}},
      assignments: %{
        "accepted" => %{
          assignment_id: "accepted",
          project_id: "PVT_test",
          phase: :accepted,
          revision: 3,
          resources: [],
          ownership: %{status: :owned, pm_id: "pm", ownership_revision: 1}
        },
        "cancelled" => %{
          assignment_id: "cancelled",
          project_id: "PVT_test",
          phase: :cancelled,
          revision: 2,
          resources: [],
          ownership: %{status: :owned, pm_id: "pm", ownership_revision: 1}
        }
      },
      requests: %{"accepted-request" => %{canonical: <<1>>, response: %{phase: :accepted}, principal_id: "pm"}}
    )
  end

  defp configure_managed_journal!(store_path) do
    path = Workflow.workflow_file_path()
    store_path = String.replace(store_path, "\\", "/")

    workflow =
      path
      |> File.read!()
      |> String.replace(
        "---\n",
        """
        ---
        managed:
          enabled: true
          store_path: "#{store_path}"
          control_token: "managed-state-schema-token"
        """,
        global: false
      )

    File.write!(path, workflow)
    WorkflowStore.force_reload()
  end

  defp store_path(label), do: Path.join(System.tmp_dir!(), "managed-state-schema-#{label}-#{System.unique_integer([:positive])}.sqlite3")
  defp unique_name(label), do: Module.concat(__MODULE__, String.to_atom("#{label}_#{System.unique_integer([:positive])}"))
end
