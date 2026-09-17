defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_launcher: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "   ",
      tracker_project_slug: "project"
    )

    assert {:error, :missing_linear_api_token} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: ""
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_launcher: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.launcher"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_launcher: "   ")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.launcher"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_launcher: "relative/codex.cmd")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "absolute Windows path"

    write_workflow_file!(Workflow.workflow_file_path(), codex_launcher: "C:/fixture/not-codex.exe")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "must name codex.cmd"

    write_workflow_file!(Workflow.workflow_file_path(), codex_launcher: "C:/fixture/codex.cmd")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "github_projects"
    assert is_binary(get_in(tracker, ["provider", "owner"]))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    managed = Map.get(config, "managed", %{})
    assert managed["enabled"] == true

    assert String.trim(prompt) != ""
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      poll_interval_ms: 30_001
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "C:/ProgramData/CodexOrchestration/config/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link starts the agent runtime" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    runtime_pid = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
        case Supervisor.restart_child(
               SymphonyElixir.Supervisor,
               SymphonyElixir.AgentRuntimeSupervisor
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(runtime_pid) do
      assert :ok =
               Supervisor.terminate_child(
                 SymphonyElixir.Supervisor,
                 SymphonyElixir.AgentRuntimeSupervisor
               )
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) == pid
    assert is_pid(Process.whereis(SymphonyElixir.TaskSupervisor))
    assert is_pid(Process.whereis(SymphonyElixir.Orchestrator))

    GenServer.stop(pid)
  end

  test "orchestrator fails startup when semantic preflight fails" do
    issue_suffix = System.unique_integer([:positive])
    orchestrator_name = Module.concat(__MODULE__, "InvalidOrchestrator#{issue_suffix}")
    workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      if pid = Process.whereis(orchestrator_name) do
        GenServer.stop(pid)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")

      if is_nil(Process.whereis(WorkflowStore)) do
        assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
      end

      if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
        assert {:ok, _pid} =
                 Supervisor.restart_child(
                   SymphonyElixir.Supervisor,
                   SymphonyElixir.AgentRuntimeSupervisor
                 )
      end
    end)

    assert :ok =
             Supervisor.terminate_child(
               SymphonyElixir.Supervisor,
               SymphonyElixir.AgentRuntimeSupervisor
             )

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, :missing_linear_project_slug} =
             Orchestrator.start_link(name: orchestrator_name)

    Process.flag(:trap_exit, previous_trap_exit)

    refute Process.whereis(orchestrator_name)
  end

  test "runtime restart keeps last good settings after an invalid reload" do
    issue_suffix = System.unique_integer([:positive])
    runtime_supervisor_name = Module.concat(__MODULE__, "ReloadRuntime#{issue_suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "ReloadTaskSupervisor#{issue_suffix}")
    orchestrator_name = Module.concat(__MODULE__, "ReloadOrchestrator#{issue_suffix}")

    on_exit(fn ->
      if pid = Process.whereis(runtime_supervisor_name) do
        GenServer.stop(pid)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_supervisor_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name
             )

    Process.unlink(runtime_pid)
    original_orchestrator_pid = Process.whereis(orchestrator_name)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()
    assert Config.settings!().tracker.kind == "memory"

    Process.exit(original_orchestrator_pid, :kill)

    restarted_orchestrator_pid =
      eventually_value(fn ->
        case Process.whereis(orchestrator_name) do
          pid when is_pid(pid) and pid != original_orchestrator_pid ->
            case Orchestrator.snapshot(orchestrator_name, 100) do
              %{} -> pid
              _ -> nil
            end

          _ ->
            nil
        end
      end)

    assert is_pid(restarted_orchestrator_pid)
    assert Process.whereis(orchestrator_name) == restarted_orchestrator_pid
    assert Process.alive?(runtime_pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent before cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    worker_alive_marker = Path.join(test_root, "worker-alive")
    cleanup_marker = Path.join(test_root, "cleanup-order")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        hook_before_remove:
          "if (Test-Path -LiteralPath '#{String.replace(worker_alive_marker, "'", "''")}') { " <>
            "[System.IO.File]::WriteAllText('#{String.replace(cleanup_marker, "'", "''")}', 'alive') } else { " <>
            "[System.IO.File]::WriteAllText('#{String.replace(cleanup_marker, "'", "''")}', 'stopped') }"
      )

      assert {:ok, workspace} = Workspace.create_for_issue(issue_identifier)
      {:ok, task_supervisor} = Task.Supervisor.start_link()

      {:ok, agent_pid} =
        Task.Supervisor.start_child(task_supervisor, fn ->
          Process.flag(:trap_exit, true)
          File.write!(worker_alive_marker, "alive")

          try do
            receive do
              {:EXIT, _from, :shutdown} -> :ok
            end
          after
            File.rm(worker_alive_marker)
          end
        end)

      assert eventually_value(fn -> if File.exists?(worker_alive_marker), do: true end)

      state = %Orchestrator.State{
        task_supervisor: task_supervisor,
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.read!(cleanup_marker) == "stopped"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: [],
      dispatchable: true
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            dispatchable: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      dispatchable: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile stops running issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "issue-unlabeled"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-562",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-562",
            state: "In Progress",
            labels: ["symphony"]
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      state: "In Progress",
      title: "Opted out active issue",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile releases a blocked issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "blocked-unlabeled"

    state = %Orchestrator.State{
      blocked: %{
        issue_id => %{
          identifier: "MT-564",
          error: "operator input required",
          worker_host: nil
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-564",
      title: "Blocked but opted out",
      state: "In Progress",
      labels: []
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "retry releases its claim when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "retry-unlabeled"

    state = %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      title: "Retry opted out",
      state: "In Progress",
      labels: []
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
        identifier: issue.identifier,
        error: "agent exited"
      })

    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
  end

  test "retry releases its claim when dispatch revalidation no longer finds the issue" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-retry-refresh-#{System.unique_integer([:positive])}"
      )

    issue_id = "retry-refreshed-issue"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        hook_before_run: "exit 1"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      {:ok, task_supervisor} = Task.Supervisor.start_link()

      state = %Orchestrator.State{
        task_supervisor: task_supervisor,
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: "MT-566",
        title: "Retry refreshed issue",
        state: "In Progress",
        dispatchable: true,
        labels: []
      }

      updated_state =
        Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
          identifier: issue.identifier,
          error: "agent exited"
        })

      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Map.has_key?(updated_state.running, issue_id)
      refute Map.has_key?(updated_state.retry_attempts, issue_id)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not continue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue = %Issue{
      id: "issue-label-continuation",
      identifier: "MT-563",
      title: "Stop after opt-out",
      state: "In Progress",
      labels: ["symphony"]
    }

    refreshed_issue = %{issue | labels: []}
    fetcher = fn ["issue-label-continuation"] -> {:ok, [refreshed_issue]} end

    assert {:done, ^refreshed_issue} =
             AgentRunner.continue_with_issue_for_test(issue, fetcher)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, 500, 1_100)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp eventually_value(fun, attempts \\ 100)

  defp eventually_value(_fun, 0), do: nil

  defp eventually_value(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on an issue from the configured tracker."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    previous_github_token = System.get_env("GITHUB_TOKEN")

    previous_control_token_file =
      Application.get_env(:symphony_elixir, :control_token_file_override)

    token_file =
      Path.join(System.tmp_dir!(), "workflow-token-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_github_token)
      File.rm(token_file)

      if previous_control_token_file do
        Application.put_env(
          :symphony_elixir,
          :control_token_file_override,
          previous_control_token_file
        )
      else
        Application.delete_env(:symphony_elixir, :control_token_file_override)
      end
    end)

    File.write!(token_file, "workflow-test-token\n")
    System.put_env("GITHUB_TOKEN", "test-github-token")
    Application.put_env(:symphony_elixir, :control_token_file_override, token_file)
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "Complete the assigned work in the provided repository workspace."
    assert prompt =~ "Symphony owns worker scheduling and peer-evidence routing."
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "prompt builder appends current review feedback after workflow prompt" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Stale issue body and template instructions")

    issue = %Issue{
      identifier: "MT-202",
      title: "Apply reviewer changes",
      description: "Original issue description",
      state: "Ready",
      url: "https://example.org/issues/MT-202",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        review_feedback: %{
          reason: "The implementation did not satisfy the acceptance contract.",
          evidence: ["Acceptance check A failed", %{check: "B", result: "missing"}]
        }
      )

    assert prompt =~ "Stale issue body and template instructions"
    assert prompt =~ "CURRENT ASSIGNMENT REVIEW FEEDBACK"
    assert prompt =~ "Reason: The implementation did not satisfy the acceptance contract."
    assert prompt =~ "- Acceptance check A failed"
    assert prompt =~ ~s(- %{check: "B", result: "missing"})

    assert :binary.match(prompt, "CURRENT ASSIGNMENT REVIEW FEEDBACK") |> elem(0) >
             :binary.match(prompt, "Stale issue body") |> elem(0)

    reason_only_prompt =
      PromptBuilder.build_prompt(issue,
        review_feedback: %{reason: "Correct the missing acceptance behavior.", evidence: []}
      )

    assert reason_only_prompt =~ "Reason: Correct the missing acceptance behavior."
    assert reason_only_prompt =~ "- No evidence supplied."
  end

  test "prompt builder injects the current project requirements with their fingerprint" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Resolve the assigned ticket.")

    issue = %Issue{identifier: "MT-REQUIREMENTS", title: "Honor current requirements", state: "Ready", labels: []}

    prompt =
      PromptBuilder.build_prompt(issue,
        project_requirements: %{content: "- Keep MFA disabled.\n", fingerprint: "sha256:requirements-current"}
      )

    assert prompt =~ "CURRENT PROJECT REQUIREMENTS"
    assert prompt =~ "Revision: sha256:requirements-current"
    assert prompt =~ "- Keep MFA disabled."
  end

  test "prompt builder marks peer reports as non-authoritative reference material" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Resolve the assigned ticket.")

    issue = %Issue{
      identifier: "MT-203",
      title: "Apply an existing review finding",
      description: "Original issue description",
      state: "Ready",
      url: "https://example.org/issues/MT-203",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        peer_reports: [
          %{
            source_assignment_id: "source",
            source_attempt_id: "attempt-1",
            report_id: "report-1",
            summary: "The parser must reject empty policy records.",
            evidence: ["reproduction"]
          }
        ]
      )

    assert prompt =~ "RELATED REVIEW REPORTS (REFERENCE ONLY)"
    assert prompt =~ "source, attempt attempt-1, report report-1"
    assert prompt =~ "parser must reject empty policy records"
    assert prompt =~ "do not change scope, ownership, or authorize provider operations"
  end

  test "prompt builder bounds large peer findings and ignores invalid collections" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Resolve the assigned ticket.")
    issue = %Issue{identifier: "MT-205", title: "Use bounded context", description: "Current assignment", labels: []}

    assert PromptBuilder.build_prompt(issue, peer_reports: :invalid) == "Resolve the assigned ticket."

    finding = %{
      source_assignment_id: "source",
      source_attempt_id: "attempt",
      report_id: "report",
      summary: String.duplicate("confirmed finding; ", 400),
      evidence: [String.duplicate("evidence", 400)]
    }

    reports = List.duplicate(finding, 8) ++ [%{summary: "NINTH REPORT MUST BE OMITTED"}]
    prompt = PromptBuilder.build_prompt(issue, peer_reports: reports)

    assert prompt =~ "RELATED REVIEW REPORTS (REFERENCE ONLY)"
    assert prompt =~ "[truncated]"
    assert String.length(prompt) < 9_000
    refute prompt =~ "NINTH REPORT MUST BE OMITTED"
  end

  test "prompt builder makes an unavailable peer-report reference explicit" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Resolve the assigned ticket.")

    issue = %Issue{
      identifier: "MT-204",
      title: "Request current context",
      description: "Original issue description",
      state: "Ready",
      url: "https://example.org/issues/MT-204",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        peer_report_notice: %{
          code: :peer_report_not_found,
          source_assignment_id: "source-assignment",
          report_id: "report-7"
        }
      )

    assert prompt =~ "RELATED REVIEW REPORT REFERENCE UNAVAILABLE"
    assert prompt =~ "source-assignment / report-7 (:peer_report_not_found)"
    assert prompt =~ "Do not assume its content remains current."
    assert prompt =~ "does not change scope, ownership, or authorize provider operations"
  end
end
