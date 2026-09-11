defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  test "response deadlines identify the pending startup or turn request despite unrelated output" do
    for method <- ["initialize", "thread/start", "thread/resume", "turn/start"] do
      test_root = Path.join(System.tmp_dir!(), "symphony-response-deadline-#{System.unique_integer([:positive])}")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-DEADLINE")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "requests.log")
      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf!(test_root) end)

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        echo "$line" >> "#{trace_file}"
        case "$line" in
          *'"method":"#{method}"'*)
            while :; do
              echo '{"method":"test/progress","params":{}}'
              sleep 0.01
            done
            ;;
          *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
          *'"method":"thread/start"'*) echo '{"id":2,"result":{"thread":{"id":"thread-deadline"}}}' ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      Workflow.set_workflow_file_path(Path.join(test_root, "WORKFLOW.md"))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_read_timeout_ms: 5_000
      )

      assert :ok = SymphonyElixir.WorkflowStore.force_reload()

      opts = if method == "thread/resume", do: [resume_thread_id: "thread-deadline"], else: []
      issue = %Issue{id: "issue-deadline", identifier: "MT-DEADLINE", title: "Response deadline", state: "In Progress"}

      assert {:error, {:response_timeout, detail}} = AppServer.run(workspace, "Run", issue, opts)
      assert detail.method == method, "pending method #{inspect(detail)}; requests: #{inspect(File.read(trace_file))}"
      assert detail.stage == if(method == "initialize", do: :initialization, else: :request)
      assert detail.timeout_ms == 5_000
      assert detail.elapsed_ms >= detail.timeout_ms
      assert detail.elapsed_ms < 10_000
    end
  end

  test "managed app server uses configured tools and repairs invalid report input in the same turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-route-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-MANAGED")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="$SYMP_TEST_CODEx_TRACE"
      printf '%s\\n' "$@" > "$trace_file.args"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-managed"},"model":"gpt-5.6-luna","reasoningEffort":null}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-managed"}}}'
            printf '%s\\n' '{"id":98,"method":"item/tool/call","params":{"tool":"orchestration_report","arguments":{"kind":"checkpoint","report_id":"report-invalid","summary":"missing evidence"}}}'
            ;;
          5)
            printf '%s\\n' '{"id":99,"method":"item/tool/call","params":{"tool":"orchestration_report","arguments":{"kind":"checkpoint","report_id":"report-1","summary":"validated","evidence":[{"test":"green"}]}}}'
            ;;
          6)
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-managed","turn":{"id":"turn-managed","status":"completed","items":[]}}}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_thread_sandbox: "danger-full-access",
        codex_turn_sandbox_policy: %{"type" => "dangerFullAccess"}
      )

      previous_codex_home = System.get_env("CODEX_HOME")
      previous_gh_config_dir = System.get_env("GH_CONFIG_DIR")
      codex_home = Path.join(Path.expand("~/.codex-other"), "nested")
      gh_config_dir = Path.join(Path.expand("~/.config/codex-orchestration"), "gh-nested")
      System.put_env("CODEX_HOME", codex_home)
      System.put_env("GH_CONFIG_DIR", gh_config_dir)

      on_exit(fn ->
        if is_binary(previous_codex_home) do
          System.put_env("CODEX_HOME", previous_codex_home)
        else
          System.delete_env("CODEX_HOME")
        end

        if is_binary(previous_gh_config_dir) do
          System.put_env("GH_CONFIG_DIR", previous_gh_config_dir)
        else
          System.delete_env("GH_CONFIG_DIR")
        end
      end)

      issue = %Issue{
        id: "issue-managed",
        identifier: "MT-MANAGED",
        title: "Managed route",
        description: "Exercise the managed app-server route",
        state: "In Progress",
        url: "https://example.org/issues/MT-MANAGED",
        labels: ["backend"]
      }

      attempt = %{
        assignment_id: "issue-managed",
        revision: "rev-1",
        generation: 0,
        attempt_id: "attempt-1"
      }

      parent = self()

      assert {:ok, _result} =
               AppServer.run(
                 workspace,
                 "Run managed turn",
                 issue,
                 managed_attempt: attempt,
                 model: "gpt-5.6-luna",
                 effort: "xhigh",
                 on_message: fn event -> send(parent, {:managed_event, event}) end,
                 report_callback: fn report ->
                   send(parent, {:managed_report, report})
                   :ok
                 end
               )

      assert_receive {:managed_report,
                      %{
                        attempt: ^attempt,
                        kind: "checkpoint",
                        report_id: "report-1",
                        summary: "validated",
                        evidence: [%{"test" => "green"}],
                        thread_id: "thread-managed",
                        turn_id: "turn-managed"
                      }}

      refute_received {:managed_report, _}
      assert_received {:managed_event, %{event: :session_started, model: "gpt-5.6-luna", effort: "xhigh"}}

      launch_args = File.read!(trace_file <> ".args")
      assert launch_args =~ "agents.enabled=false"
      refute launch_args =~ "--disable"
      refute launch_args =~ "permissions."
      refute launch_args =~ "mcp_servers."

      payloads =
        trace_file
        |> File.read!()
        |> String.split("JSON:", trim: true)
        |> Enum.map(&String.trim_trailing(&1, "\\n"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)

      initialize = Enum.find(payloads, &(&1["method"] == "initialize"))
      assert get_in(initialize, ["params", "clientInfo", "version"]) == to_string(Application.spec(:symphony_elixir, :vsn))

      thread_start = Enum.find(payloads, &(&1["method"] == "thread/start"))
      assert get_in(thread_start, ["params", "model"]) == "gpt-5.6-luna"
      assert get_in(thread_start, ["params", "sandbox"]) == "danger-full-access"

      assert get_in(thread_start, ["params", "developerInstructions"]) =~
               "current managed assignment and its latest revision are your work authority"

      assert get_in(thread_start, ["params", "developerInstructions"]) =~
               "Ignore inherited scrum-master or delegation guidance"

      refute Map.has_key?(thread_start["params"], "permissions")

      assert Enum.any?(get_in(thread_start, ["params", "dynamicTools"]), fn tool ->
               tool["name"] == "orchestration_report" and
                 get_in(tool, ["inputSchema", "required"]) ==
                   ["kind", "report_id", "summary", "evidence"]
             end)

      turn_start = Enum.find(payloads, &(&1["method"] == "turn/start"))
      assert get_in(turn_start, ["params", "model"]) == "gpt-5.6-luna"
      assert get_in(turn_start, ["params", "effort"]) == "xhigh"
      assert get_in(turn_start, ["params", "sandboxPolicy"]) == %{"type" => "dangerFullAccess"}
      refute Map.has_key?(turn_start["params"], "permissions")
      assert Enum.count(payloads, &(&1["method"] == "turn/start")) == 1
      refute Enum.any?(payloads, &(&1["method"] == "turn/interrupt"))
      invalid_response = Enum.find(payloads, &(&1["id"] == 98))
      assert get_in(invalid_response, ["result", "success"]) == false
      assert Jason.encode!(invalid_response) =~ "execution identity is attached by the runtime"
      assert Enum.any?(payloads, &(&1["id"] == 99 and get_in(&1, ["result", "success"]) == true))
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal reports use an independent stop-read budget while draining final usage" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-terminal-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TERMINAL")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-terminal.trace")
      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="$SYMP_TEST_CODEx_TRACE"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-terminal"},"model":"gpt-5.6-luna","reasoningEffort":null}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-terminal"}}}'
            printf '%s\\n' '{"id":99,"method":"item/tool/call","params":{"tool":"orchestration_report","arguments":{"kind":"result","report_id":"report-terminal","summary":"done","evidence":[]}}}'
            ;;
          5) ;;
          6)
            printf '%s\\n' '{"id":5,"result":{}}'
            printf '%s\\n' '{"id":100,"method":"item/tool/call","params":{"tool":"forbidden_after_report","arguments":{}}}'
            ;;
          7)
            sleep 0.5
            printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-terminal","tokenUsage":{"total":{"inputTokens":714937,"outputTokens":18786,"totalTokens":733723}}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-terminal","turn":{"id":"turn-terminal","status":"interrupted"}}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_read_timeout_ms: 250
      )

      issue = %Issue{
        id: "issue-terminal",
        identifier: "MT-TERMINAL",
        title: "Terminal report",
        description: "Stop the active turn after a terminal report",
        state: "In Progress",
        url: "https://example.org/issues/MT-TERMINAL",
        labels: ["backend"]
      }

      attempt = %{
        assignment_id: "issue-terminal",
        revision: "rev-1",
        generation: 0,
        attempt_id: "attempt-terminal"
      }

      observer = self()

      assert {:error, {:orchestration_report_terminal, report}} =
               AppServer.run(
                 workspace,
                 "Report result",
                 issue,
                 managed_attempt: attempt,
                 model: "gpt-5.6-luna",
                 effort: "xhigh",
                 report_callback: fn _report -> :ok end,
                 on_message: fn event -> send(observer, {:terminal_event, event}) end,
                 tool_executor: fn tool, _args -> flunk("Unexpected post-report tool: #{tool}") end
               )

      assert report.kind == "result"
      assert report.report_id == "report-terminal"
      assert_received {:terminal_event, %{payload: %{"method" => "thread/tokenUsage/updated", "params" => %{"tokenUsage" => usage}}}}
      assert usage["total"]["totalTokens"] == 733_723
      refute_received {:terminal_event, %{event: :final_usage_incomplete}}

      payloads =
        trace_file
        |> File.read!()
        |> String.split("JSON:", trim: true)
        |> Enum.map(&String.trim_trailing(&1, "
"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(payloads, fn payload ->
               payload["method"] == "turn/interrupt" and
                 get_in(payload, ["params", "threadId"]) == "thread-terminal" and
                 get_in(payload, ["params", "turnId"]) == "turn-terminal"
             end)

      assert Enum.any?(payloads, &(&1["id"] == 100 and get_in(&1, ["error", "code"]) == -32_000))
    after
      File.rm_rf(test_root)
    end
  end

  test "managed route rejects unsupported models, unreasoned escalation, and stale route metadata" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-route-reject-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-MANAGED-REJECT")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

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
    after
      File.rm_rf(test_root)
    end
  end

  test "managed app server resumes the exact thread and preserves route fields" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-resume-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-RESUME")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-resume.trace")
      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="$SYMP_TEST_CODEx_TRACE"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3)
            printf '%s\\n' '{"id":4,"result":{"thread":{"id":"thread-resume"},"model":"gpt-5.6-sol","reasoningEffort":null}}'
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-resume"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-resume","turn":{"id":"turn-resume","status":"completed","items":[]}}}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-resume",
        identifier: "MT-RESUME",
        title: "Resume route",
        description: "Resume the existing thread",
        state: "In Progress",
        url: "https://example.org/issues/MT-RESUME",
        labels: ["backend"]
      }

      attempt = %{
        assignment_id: "issue-resume",
        revision: "rev-2",
        generation: 2,
        attempt_id: "attempt-2"
      }

      assert {:ok, _result} =
               AppServer.run(
                 workspace,
                 "Continue managed turn",
                 issue,
                 managed_attempt: attempt,
                 model: "gpt-5.6-sol",
                 effort: "max",
                 escalation_reason: "Connected recovery requires the strongest worker route",
                 resume_thread_id: "thread-resume"
               )

      payloads =
        trace_file
        |> File.read!()
        |> String.split("JSON:", trim: true)
        |> Enum.map(&String.trim_trailing(&1, "\\n"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)

      refute Enum.any?(payloads, &(&1["method"] == "thread/start"))
      resume = Enum.find(payloads, &(&1["method"] == "thread/resume"))
      assert get_in(resume, ["params", "threadId"]) == "thread-resume"
      assert get_in(resume, ["params", "model"]) == "gpt-5.6-sol"

      assert get_in(resume, ["params", "developerInstructions"]) =~
               "current managed assignment and its latest revision are your work authority"

      turn_start = Enum.find(payloads, &(&1["method"] == "turn/start"))
      assert get_in(turn_start, ["params", "model"]) == "gpt-5.6-sol"
      assert get_in(turn_start, ["params", "effort"]) == "max"
    after
      File.rm_rf(test_root)
    end
  end

  test "managed stale stop cannot terminate a newer attempt in the same workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-stale-stop-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-STALE-STOP")
    codex_binary = Path.join(test_root, "fake-codex")
    File.mkdir_p!(workspace)

    File.write!(codex_binary, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-stale"},"model":"gpt-5.6-luna","reasoningEffort":null}}' ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    attempt_a = %{
      assignment_id: "issue-stale-stop",
      revision: "rev-1",
      generation: 1,
      attempt_id: "attempt-a"
    }

    attempt_b = %{attempt_a | generation: 2, attempt_id: "attempt-b"}

    session_a = nil
    session_b = nil

    try do
      assert {:ok, session_a} =
               AppServer.start_session(workspace,
                 managed_attempt: attempt_a,
                 model: "gpt-5.6-luna",
                 effort: "xhigh"
               )

      assert {:ok, session_b} =
               AppServer.start_session(workspace,
                 managed_attempt: attempt_b,
                 model: "gpt-5.6-luna",
                 effort: "xhigh"
               )

      unit_a = session_a.metadata.systemd_unit
      unit_b = session_b.metadata.systemd_unit
      pid_b = session_b.metadata.codex_process_identity.pid
      assert unit_a != unit_b

      assert {_, 0} =
               System.cmd(
                 "systemctl",
                 [
                   "--user",
                   "kill",
                   "--kill-who=all",
                   "--signal=KILL",
                   unit_a
                 ],
                 stderr_to_stdout: true
               )

      Process.sleep(150)
      assert :ok = AppServer.stop_session(session_a)
      assert File.exists?("/proc/#{pid_b}")
      assert {state, 0} = System.cmd("systemctl", ["--user", "show", unit_b, "--property=ActiveState", "--value"])
      assert String.trim(state) == "active"
    after
      stop_optional_session(session_a)
      stop_optional_session(session_b)

      File.rm_rf(test_root)
    end
  end

  test "recorded process metadata stops an owned scope after the port is gone" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-recorded-stop-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-RECORDED-STOP")
    codex_binary = Path.join(test_root, "fake-codex")
    File.mkdir_p!(workspace)

    File.write!(codex_binary, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-recorded"},"model":"gpt-5.6-luna","reasoningEffort":null}}' ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    metadata = nil

    try do
      assert {:ok, session} =
               AppServer.start_session(workspace,
                 managed_attempt: %{
                   assignment_id: "issue-recorded-stop",
                   revision: "rev-1",
                   generation: 1,
                   attempt_id: "attempt-recorded"
                 },
                 model: "gpt-5.6-luna",
                 effort: "xhigh"
               )

      metadata = session.metadata
      assert Port.close(session.port)
      Process.sleep(250)
      assert :ok = AppServer.stop_recorded_process(metadata)

      assert {state, 0} =
               System.cmd("systemctl", [
                 "--user",
                 "show",
                 metadata.systemd_unit,
                 "--property=ActiveState",
                 "--value"
               ])

      assert String.trim(state) in ["inactive", "failed"]
    after
      stop_optional_recorded_metadata(metadata)

      File.rm_rf(test_root)
    end
  end

  defp stop_optional_session(session) do
    case session do
      %{port: _} = session -> AppServer.stop_session(session)
      _ -> :ok
    end
  end

  defp stop_optional_recorded_metadata(metadata) do
    case metadata do
      metadata when is_map(metadata) -> AppServer.stop_recorded_process(metadata)
      _ -> :ok
    end
  end

  test "managed sessions reject a missing or wrong server model on start and resume" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-model-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-MODEL")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      attempt = %{
        assignment_id: "issue-model",
        revision: "rev-1",
        generation: 0,
        attempt_id: "attempt-model"
      }

      for {response_id, extra_response, opts} <- [
            {2, ~s(,"model":"gpt-5.6-terra","reasoningEffort":null), []},
            {4, ~s(,"model":"gpt-5.6-terra","reasoningEffort":null), [resume_thread_id: "thread-model"]},
            {2, "", []}
          ] do
        File.write!(codex_binary, """
        #!/bin/sh
        count=0
        while IFS= read -r _line; do
          count=$((count + 1))
          case "$count" in
            1) printf '%s
        ' '{"id":1,"result":{}}' ;;
            2) ;;
            3) printf '%s
        ' '{"id":#{response_id},"result":{"thread":{"id":"thread-model"}#{extra_response}}}' ;;
            *) exit 0 ;;
          esac
        done
        """)

        File.chmod!(codex_binary, 0o755)

        assert {:error, reason} =
                 AppServer.start_session(
                   workspace,
                   Keyword.merge(
                     [managed_attempt: attempt, model: "gpt-5.6-luna", effort: "xhigh"],
                     opts
                   )
                 )

        assert reason in [
                 {:managed_model_mismatch, "gpt-5.6-luna", "gpt-5.6-terra"},
                 {:managed_model_missing, "gpt-5.6-luna"}
               ]
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "modern completed notifications preserve failed and interrupted turn status" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-turn-status-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-STATUS")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-status",
        identifier: "MT-STATUS",
        title: "Modern status",
        description: "Preserve structured completion status",
        state: "In Progress",
        url: "https://example.org/issues/MT-STATUS",
        labels: ["backend"]
      }

      for {status, expected_tag} <- [{"failed", :turn_failed}, {"interrupted", :turn_interrupted}] do
        File.write!(codex_binary, """
        #!/bin/sh
        count=0
        while IFS= read -r _line; do
          count=$((count + 1))
          case "$count" in
            1) printf '%s\\n' '{"id":1,"result":{}}' ;;
            2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-status"}}}' ;;
            3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-status"}}}' ;;
            4) printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-status","turn":{"id":"turn-status","status":"#{status}","items":[]}}}' ;;
          esac
        done
        """)

        File.chmod!(codex_binary, 0o755)

        assert {:error, {^expected_tag, details}} =
                 AppServer.run(workspace, "Status turn", issue)

        assert get_in(details, ["turn", "status"]) == status
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "turn timeout resets on stream updates and fires after silence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-turn-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TIMEOUT")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-timeout"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-timeout"}}}'
            sleep 0.15
            printf '%s\\n' '{"method":"item/updated","params":{"item":{"id":"one"}}}'
            sleep 0.15
            printf '%s\\n' '{"method":"item/updated","params":{"item":{"id":"two"}}}'
            sleep 0.15
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_timeout_ms: 250
      )

      issue = %Issue{
        id: "issue-turn-timeout",
        identifier: "MT-TIMEOUT",
        title: "Stream timeout",
        description: "Keep active streams alive",
        state: "In Progress",
        url: "https://example.org/issues/MT-TIMEOUT",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "stream updates", issue)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-silent"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-silent"}}}'
            sleep 0.4
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_timeout_ms: 100
      )

      assert {:error, :turn_timeout} = AppServer.run(workspace, "silent turn", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes explicit turn sandbox policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-turn-policies.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{"type" => "workspaceWrite", "writableRoots" => ["relative/path"], "networkAccess" => true},
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == configured_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-input.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            printf '%s\\n' '{\"method\":\"turn/input_required\",\"id\":\"resp-1\",\"params\":{\"requiresInput\":true,\"reason\":\"blocked\"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy codex input",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats MCP elicitation requests as hard input blockers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-elicitation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-188")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-188"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-188"}}}'
            printf '%s\\n' '{"method":"mcpServer/elicitation/request","params":{"message":"Need operator input"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-mcp-elicitation",
        identifier: "MT-188",
        title: "MCP elicitation",
        description: "Cannot satisfy MCP input",
        state: "In Progress",
        url: "https://example.org/issues/MT-188",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs MCP input", issue)

      assert payload["method"] == "mcpServer/elicitation/request"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server surfaces unexpected command approval without manufacturing authorization" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-89\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-89\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"gh pr view\",\"cwd\":\"/tmp\",\"reason\":\"need approval\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, _payload}} = AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and
                   case get_in(payload, ["params", "dynamicTools"]) do
                     [
                       %{
                         "description" => description,
                         "inputSchema" => %{"required" => ["query"]},
                         "name" => "linear_graphql"
                       }
                     ] ->
                       description =~ "Linear"

                     _ ->
                       false
                   end
               else
                 false
               end
             end)

      refute Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and Map.has_key?(payload, "result")
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server never answers MCP approval questions on the user behalf" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-717\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-717\"}}}'
            printf '%s\\n' '{\"id\":110,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-717\",\"questions\":[{\"header\":\"Approve app tool call?\",\"id\":\"mcp_tool_call_approval_call-717\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Run the tool and continue.\",\"label\":\"Approve Once\"},{\"description\":\"Run the tool and remember this choice for this session.\",\"label\":\"Approve this Session\"},{\"description\":\"Decline this tool call and continue.\",\"label\":\"Deny\"},{\"description\":\"Cancel this tool call\",\"label\":\"Cancel\"}],\"question\":\"The linear MCP server wants to run the tool \\\"Save issue\\\", which may modify or delete data. Allow this action?\"}],\"threadId\":\"thread-717\",\"turnId\":\"turn-717\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, _payload}} = AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      refute Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and Map.has_key?(payload, "result")
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks freeform tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
            printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle generic tool input", issue)

      assert payload["method"] == "item/tool/requestUserInput"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks option-based tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-719\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-719\"}}}'
            printf '%s\\n' '{\"id\":112,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-719\",\"questions\":[{\"header\":\"Choose an action\",\"id\":\"options-719\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Proceed with the requested action.\",\"label\":\"Allow\"},{\"description\":\"Do not proceed.\",\"label\":\"Deny\"}],\"question\":\"How should I proceed?\"}],\"threadId\":\"thread-719\",\"turnId\":\"turn-719\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input block",
        description: "Ensure option prompts require operator input",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      assert payload["method"] == "item/tool/requestUserInput"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"some_tool\",\"callId\":\"call-90\",\"threadId\":\"thread-90\",\"turnId\":\"turn-90\",\"arguments\":{}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   String.contains?(
                     get_in(payload, ["result", "output"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90a\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90a\"}}}'
            printf '%s\\n' '{\"id\":102,\"method\":\"item/tool/call\",\"params\":{\"name\":\"linear_graphql\",\"callId\":\"call-90a\",\"threadId\":\"thread-90a\",\"turnId\":\"turn-90a\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"includeTeams\":false}}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call-failed.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call-failed.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90b\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90b\"}}}'
            printf '%s\\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90b\",\"threadId\":\"thread-90b\",\"turnId\":\"turn-90b\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\"}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

      assert_received {:app_server_message, %{event: :tool_call_failed, payload: %{"params" => %{"tool" => "linear_graphql"}}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server captures codex side output and logs it through Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            printf '%s\\n' 'warning: this is stderr noise' >&2
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "Codex turn stream output: warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits malformed events for JSON-like protocol lines that fail to decode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93"}}}'
            printf '%s\\n' '{"method":"turn/completed"'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: "{\"method\":\"turn/completed\""}}
      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server does not pass tracker credentials to the local Codex child" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-secret-env-#{System.unique_integer([:positive])}"
      )

    custom_secret_env = "SYMP_CUSTOM_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    profile_marker_env = "SYMP_TEST_BASH_PROFILE_LOADED_#{System.unique_integer([:positive])}"
    previous_secret = System.get_env("LINEAR_API_KEY")
    previous_custom_secret = System.get_env(custom_secret_env)
    previous_home = System.get_env("HOME")
    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_secret)
      restore_env(custom_secret_env, previous_custom_secret)
      restore_env("HOME", previous_home)
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
    end)

    try do
      bash_home = Path.join(test_root, "bash-home")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SECRET")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-secret-env.trace")

      File.mkdir_p!(bash_home)
      File.mkdir_p!(workspace)

      File.write!(Path.join(bash_home, ".bash_profile"), """
      export LINEAR_API_KEY='profile-canonical-secret-that-must-not-reach-child'
      export #{custom_secret_env}='profile-custom-secret-that-must-not-reach-child'
      export #{profile_marker_env}=1
      """)

      System.put_env("LINEAR_API_KEY", "canonical-secret-that-must-not-reach-child")
      System.put_env(custom_secret_env, "custom-secret-that-must-not-reach-child")
      System.put_env("HOME", bash_home)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="$SYMP_TEST_CODEx_TRACE"
      printf 'PROFILE_LOADED:%s\\n' "$#{profile_marker_env}" >> "$trace_file"
      printf 'CANONICAL_SECRET:%s\\n' "$LINEAR_API_KEY" >> "$trace_file"
      printf 'CUSTOM_SECRET:%s\\n' "$#{custom_secret_env}" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-secret"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-secret"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "$#{custom_secret_env}",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-secret-env",
        identifier: "MT-SECRET",
        title: "Keep tracker auth in Symphony",
        description: "Ensure the child cannot bypass the centrally-authenticated tool boundary",
        state: "In Progress",
        url: "https://example.org/issues/MT-SECRET",
        labels: ["security"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Do not inherit tracker auth", issue)
      assert File.read!(trace_file) =~ "PROFILE_LOADED:1\n"
      assert File.read!(trace_file) =~ "CANONICAL_SECRET:\n"
      assert File.read!(trace_file) =~ "CUSTOM_SECRET:\n"
      refute File.read!(trace_file) =~ "secret-that-must-not-reach-child"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server launches over ssh for remote workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-ssh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        codex_command: "fake-remote-codex app-server"
      )

      issue = %Issue{
        id: "issue-remote",
        identifier: "MT-REMOTE",
        title: "Run remote app server",
        description: "Validate ssh-backed codex startup",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
      assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
      assert argv_line =~ "cd "
      assert argv_line =~ remote_workspace
      assert argv_line =~ "unset LINEAR_API_KEY"
      assert argv_line =~ "exec "
      assert argv_line =~ "fake-remote-codex app-server"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
