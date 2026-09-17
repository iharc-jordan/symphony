defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  test "managed launcher disables both stable multi-agent feature gates" do
    assert AppServer.managed_cli_overrides() == [
             "-c",
             "features.multi_agent=false",
             "-c",
             "features.multi_agent_v2=false"
           ]
  end

  test "managed launcher marks only managed worker child environments" do
    assert AppServer.managed_worker_environment(%{}) == [{~c"SYMPHONY_MANAGED_WORKER", ~c"1"}]
    assert AppServer.managed_worker_environment(nil) == []
  end

  test "managed route rejects unsupported models, unreasoned escalation, and stale metadata before launch" do
    root = Path.join(System.tmp_dir!(), "managed-route-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    {:ok, workspace} = Workspace.create_for_issue("MT-MANAGED-REJECT")
    on_exit(fn -> File.rm_rf!(root) end)

    attempt = %{
      assignment_id: "issue-managed-reject",
      revision: "rev-1",
      generation: 1,
      attempt_id: "attempt-1"
    }

    assert {:error, {:managed_model_not_allowed, "gpt-6-astra", _}} =
             AppServer.start_session(workspace,
               managed_attempt: attempt,
               model: "gpt-6-astra"
             )

    assert {:error, :managed_escalation_reason_required} =
             AppServer.start_session(workspace,
               managed_attempt: attempt,
               model: "gpt-5.6-terra",
               effort: "xhigh"
             )

    stale_attempt = Map.put(attempt, :model, "gpt-5.6-terra")

    assert {:error, {:managed_route_mismatch, :model, "gpt-5.6-terra", "gpt-5.6-luna"}} =
             AppServer.start_session(workspace,
               managed_attempt: stale_attempt,
               model: "gpt-5.6-luna"
             )
  end

  test "app server refuses the workspace root, outside paths, and unowned descendants" do
    root = Path.join(System.tmp_dir!(), "app-server-cwd-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    outside = Path.join(root, "outside")
    unowned = Path.join(workspace_root, "unowned")
    File.mkdir_p!(outside)
    File.mkdir_p!(unowned)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    on_exit(fn -> File.rm_rf!(root) end)

    issue = %Issue{id: "guard", identifier: "MT-GUARD", state: "In Progress"}

    assert {:error, {:invalid_workspace_cwd, {:workspace_outside_root, _}}} =
             AppServer.run(workspace_root, "guard", issue)

    assert {:error, {:invalid_workspace_cwd, {:workspace_outside_root, _}}} =
             AppServer.run(outside, "guard", issue)

    assert {:error, {:invalid_workspace_cwd, {:workspace_unowned, _}}} =
             AppServer.run(unowned, "guard", issue)
  end

  test "terminal orchestration report drains final usage exactly once" do
    node = System.find_executable("node.exe") || System.find_executable("node")
    assert is_binary(node)

    fixture = Path.expand("../fixtures/terminal_report_app_server.mjs", __DIR__)

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        args: [fixture]
      ])

    on_exit(fn ->
      if :erlang.port_info(port) != :undefined, do: Port.close(port)
    end)

    owner = self()
    on_message = fn message -> send(owner, {:app_server_event, message}) end

    attempt = %{
      assignment_id: "item-terminal-report",
      revision: 1,
      generation: 1,
      attempt_id: "attempt-terminal-report"
    }

    session = %{
      port: port,
      metadata: %{os_pid: nil},
      approval_policy: "never",
      turn_sandbox_policy: %{"type" => "dangerFullAccess"},
      thread_id: "thread-terminal-report",
      workspace: System.tmp_dir!(),
      dynamic_tool_binding: %{},
      managed_attempt: attempt,
      turn_model: "gpt-5.6-luna",
      turn_effort: "xhigh",
      report_callback: fn _report -> :ok end
    }

    issue = %Issue{
      id: "item-terminal-report",
      identifier: "MT-TERMINAL",
      title: "Terminal report drain",
      state: "In Progress"
    }

    assert {:error, {:orchestration_report_terminal, %{kind: "result", report_id: "report-terminal", summary: "completed", evidence: []}}} =
             AppServer.run_turn(session, "finish", issue, on_message: on_message)

    events = collect_app_server_events([])

    assert Enum.count(events, &(&1.event == :final_usage_complete)) == 1
    refute Enum.any?(events, &(&1.event == :final_usage_incomplete))

    assert Enum.all?(
             Enum.filter(events, &(&1.event == :turn_ended_with_error)),
             &match?({:orchestration_report_terminal, _report}, &1.reason)
           )
  end

  defp collect_app_server_events(events) do
    receive do
      {:app_server_event, event} -> collect_app_server_events([event | events])
    after
      100 -> Enum.reverse(events)
    end
  end
end
