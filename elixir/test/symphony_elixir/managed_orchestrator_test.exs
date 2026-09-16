defmodule SymphonyElixir.ManagedOrchestratorTestControl do
  alias SymphonyElixir.Managed.{Control, Principal}

  # Existing lifecycle scenarios use one explicit PM and Project. Ownership
  # adversarial tests call the authenticated API directly with their own fences.
  def principal, do: %{principal_id: "00000000-0000-4000-8000-000000000001", role: :pm, project_scope: :all}

  def envelope(%{operation: operation} = request) when operation in [:bind_project, "bind_project"], do: request

  def envelope(request) do
    update_in(request, [:args], fn args ->
      args
      |> Map.put_new(:project_id, "PVT_test")
      |> Map.put_new(:expected_ownership_revision, 1)
    end)
  end

  def submit(pid, request) do
    principal = if request.operation in [:bind_project, "bind_project"], do: Principal.operator(), else: principal()
    Control.submit_authorized(pid, envelope(request), principal)
  end
end

defmodule SymphonyElixir.ManagedReviewEffectsStub do
  def review(assignment, _args, _context) do
    if is_pid(assignment[:review_observer]), do: send(assignment.review_observer, :managed_review_effect_called)

    {:ok,
     %{
       provider_state: :review,
       provider_final_state: :accepted,
       issue_final_state: :closed,
       reconciled: true,
       external_effects: %{status: :ok, issue_close: :ok}
     }}
  end

  def transition(_assignment, target, _context) do
    {:ok, %{provider_state: target, reconciled: true, external_effects: %{status: :ok}}}
  end
end

defmodule SymphonyElixir.ManagedDeferredTransitionStub do
  def transition(_assignment, target, %{process_stopped: false}) when target in [:waiting, :cancelled] do
    {:error, :managed_process_not_stopped, %{}}
  end

  def transition(_assignment, target, _context) do
    {:ok, %{provider_state: target, reconciled: true, external_effects: %{status: :ok}}}
  end
end

defmodule SymphonyElixir.ManagedCountingTransitionStub do
  def transition(assignment, target, _context) do
    if is_pid(assignment[:transition_observer]) do
      send(assignment[:transition_observer], {:managed_transition_effect, assignment.assignment_id, target})
    end

    {:ok, %{provider_state: target, reconciled: true, external_effects: %{status: :ok}}}
  end
end

defmodule SymphonyElixir.ManagedRequirementsTransitionStub do
  def transition(assignment, target, _context) do
    observer = assignment[:transition_observer]
    expected = assignment[:expected_requirements_fingerprint]

    if assignment[:requirements_fingerprint] == expected do
      if is_pid(observer) do
        send(observer, {:requirements_transition, assignment})
        send(observer, {:requirements_transition_target, target, assignment})
      end

      {:ok, %{provider_state: target, reconciled: true, external_effects: %{status: :ok}}}
    else
      if is_pid(observer) do
        send(observer, {:requirements_transition_rejected, assignment})
        send(observer, {:requirements_transition_target, target, assignment})
      end

      {:error, :requirements_changed, %{expected: expected, actual: assignment[:requirements_fingerprint]}}
    end
  end
end

defmodule SymphonyElixir.ManagedOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.{Control, Journal, Rules, Usage}

  defp binding_args do
    %{
      expected_revision: 0,
      project: %{
        project_id: "PVT_test",
        project_number: 4,
        status_field_id: "PVTSSF_test",
        status_options: %{"READY" => "ready", "ACTIVE" => "active", "REVIEW" => "review", "ACCEPTED" => "accepted", "WAITING" => "waiting", "CANCELLED" => "cancelled"},
        repositories: ["acme/example"]
      }
    }
  end

  defp enrollment_args do
    %{
      expected_revision: 1,
      assignment_id: "item-1",
      repository: "acme/example",
      issue_number: 5,
      base_commit: "base",
      board_state: "READY",
      resources: [%{kind: :repository, authority: "github.com", identity: "acme/example", access: :write}],
      dependencies: [],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"}
    }
  end

  defp managed_server(opts \\ []) do
    name = Module.concat(__MODULE__, :"server_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "managed-orchestrator-#{System.unique_integer([:positive])}.log")
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        task_supervisor: task_supervisor,
        managed_effects: SymphonyElixir.ManagedReviewEffectsStub
      )

    {:ok, journal, %{}} = Journal.open(path, name: String.to_atom("managed_test_#{System.unique_integer([:positive])}"))

    :sys.replace_state(pid, fn state ->
      data = Rules.new(disabled: Keyword.get(opts, :disabled, false))
      managed = %{journal: journal, data: data, effects: SymphonyElixir.ManagedReviewEffectsStub}
      %{state | managed: managed, poll_check_in_progress: true}
    end)

    on_exit(fn ->
      stop_if_alive(pid)
      stop_if_alive(task_supervisor)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    {pid, path}
  end

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp managed_usage_update(attempt, input, output, total) do
    %{
      attempt: attempt,
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{"inputTokens" => input, "outputTokens" => output, "totalTokens" => total}
          }
        }
      }
    }
  end

  defp git_output!(git, arguments) do
    case System.cmd(git, arguments, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git fixture command failed (#{status}) #{inspect(arguments)}: #{output}"
    end
  end

  defp checkout_fixture_repository!(root) do
    git = System.find_executable("git") || raise "git executable is required for managed checkout test"
    source = Path.join(root, "source")
    remote = Path.join(root, "remote.git")

    File.mkdir_p!(source)
    git_output!(git, ["init", source])
    File.write!(Path.join(source, "fixture.txt"), "managed checkout fixture\n")
    git_output!(git, ["-C", source, "add", "fixture.txt"])

    git_output!(git, [
      "-C",
      source,
      "-c",
      "user.email=fixture@example.test",
      "-c",
      "user.name=Managed Checkout Fixture",
      "commit",
      "-m",
      "fixture"
    ])

    base_commit = git_output!(git, ["-C", source, "rev-parse", "HEAD"])
    git_output!(git, ["init", "--bare", remote])
    git_output!(git, ["-C", source, "remote", "add", "origin", remote])
    git_output!(git, ["-C", source, "push", "origin", "HEAD"])
    %{git: git, remote: remote, base_commit: base_commit}
  end

  for scenario <- [:fresh, :resume, :escalate] do
    @dispatch_scenario scenario
    test "managed dispatch prepares the checkout with the required session mode: #{scenario}" do
      root = Path.join(System.tmp_dir!(), "managed-dispatch-checkout-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}")
      workspaces = Path.join(root, "workspaces")

      # Stop the ordinary scheduler before its configuration changes to this
      # fixture. Its unmanaged dispatch path cannot satisfy this assertion.
      default_orchestrator = Process.whereis(SymphonyElixir.Orchestrator)

      if is_pid(default_orchestrator) do
        :ok = Supervisor.terminate_child(SymphonyElixir.AgentRuntimeSupervisor, SymphonyElixir.Orchestrator)
      end

      %{remote: remote, base_commit: base_commit} = checkout_fixture_repository!(root)

      File.write!(Workflow.workflow_file_path(), """
      ---
      tracker:
        kind: memory
        active_states: [READY, ACTIVE]
        terminal_states: [ACCEPTED, CANCELLED]
      polling:
        interval_ms: 60000
      workspace:
        root: #{workspaces}
      ---
      Direct Git managed checkout test.
      """)

      :ok = WorkflowStore.force_reload()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)

        if is_pid(default_orchestrator) and is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
          assert {:ok, _pid} =
                   Supervisor.restart_child(SymphonyElixir.AgentRuntimeSupervisor, SymphonyElixir.Orchestrator)
        end
      end)

      issue = %Issue{
        id: "item-1",
        identifier: "acme/example#5",
        title: "Checkout fixture",
        state: "READY",
        dispatchable: true,
        native_ref: %{
          "project_item_id" => "item-1",
          "issue_id" => "I_fixture",
          "issue_number" => 5,
          "repository" => %{"id" => "R_fixture", "name_with_owner" => "acme/example", "url" => remote}
        }
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      previous_state_root = Application.get_env(:symphony_elixir, :managed_state_root)
      Application.put_env(:symphony_elixir, :managed_state_root, Path.join(root, "managed-state"))

      previous_managed_mode = Application.get_env(:symphony_elixir, :managed_mode)
      Application.put_env(:symphony_elixir, :managed_mode, true)

      on_exit(fn ->
        if is_nil(previous_state_root),
          do: Application.delete_env(:symphony_elixir, :managed_state_root),
          else: Application.put_env(:symphony_elixir, :managed_state_root, previous_state_root)

        if is_nil(previous_managed_mode),
          do: Application.delete_env(:symphony_elixir, :managed_mode),
          else: Application.put_env(:symphony_elixir, :managed_mode, previous_managed_mode)
      end)

      {pid, _path} = managed_server(disabled: true)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(root)
      end)

      assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
      args = %{enrollment_args() | base_commit: base_commit}
      assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: args})

      if @dispatch_scenario == :resume do
        :sys.replace_state(pid, fn state ->
          data =
            update_in(state.managed.data, [:assignments, "item-1"], fn assignment ->
              Map.merge(assignment, %{resume_ready: true, thread_id: "stored-thread", generation: 2, recovery_generation_pending: true})
            end)

          %{state | managed: %{state.managed | data: data}}
        end)
      end

      :sys.replace_state(pid, fn state ->
        data =
          update_in(state.managed.data, [:assignments, "item-1"], fn assignment ->
            updates = %{
              attempt_id: "fixture-attempt-#{System.unique_integer([:positive])}",
              generation: Map.get(assignment, :generation, 1),
              phase: :active
            }

            updates =
              if @dispatch_scenario == :escalate do
                Map.merge(updates, %{
                  route: %{model: "gpt-5.6-terra", effort: "xhigh"},
                  escalation_reason: "Complex diagnosis"
                })
              else
                updates
              end

            Map.merge(assignment, updates)
          end)

        %{state | managed: %{state.managed | data: data}}
      end)

      run_options = pid |> :sys.get_state() |> Orchestrator.managed_run_options_for_test(issue)
      assert is_function(run_options[:workspace_preparer], 1)
      assert %{assignment_id: "item-1", attempt_id: attempt_id} = run_options[:managed_attempt]
      assert is_binary(attempt_id)
      assert run_options[:max_turns] == 20
      assert run_options[:remaining_turns] == 20

      if @dispatch_scenario == :resume do
        assert run_options[:resume_thread_id] == "stored-thread"
      else
        refute Keyword.has_key?(run_options, :resume_thread_id)
      end

      assert run_options[:model] == if(@dispatch_scenario == :escalate, do: "gpt-5.6-terra", else: "gpt-5.6-luna")
      assert run_options[:effort] == "xhigh"
      assert :sys.get_state(pid).running == %{}
      assert :sys.get_state(pid).managed.data.disabled == true

      # The runner creates the workspace before invoking the managed checkout.
      # Prove the safety boundary has recorded ownership before exercising the
      # real Git preparer, so a failure below is not mistaken for a Git error.
      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert {:ok, ^workspace} = Workspace.validate_owned_workspace(workspace)
      assert :ok = run_options[:workspace_preparer].(workspace)

      assert git_output!(System.find_executable("git"), ["-C", workspace, "rev-parse", "HEAD"]) == args.base_commit
      assert git_output!(System.find_executable("git"), ["-C", workspace, "remote", "get-url", "origin"]) == remote

      GenServer.stop(pid)
    end
  end

  test "managed control is serialized, durable, and exposes revision and cursor" do
    {pid, _path} = managed_server()

    assert {:ok, %{operation: :bind_project, revision: 1}} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: "bind_project", args: binding_args()})

    assert {:ok, %{operation: :enroll, assignment_id: "item-1", revision: 1}} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: "enroll", args: enrollment_args()})

    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.revision == 2
    assert snapshot.cursor == 2
    assert snapshot.assignments["item-1"].repository == "acme/example"

    assert {:ok, duplicate} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: "enroll", args: enrollment_args()})

    assert duplicate.duplicate == true
  end

  test "accepted review journals intent and service reconciliation before commit" do
    {pid, _path} = managed_server()
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    :sys.replace_state(pid, fn state ->
      data =
        state.managed.data
        |> put_in([:assignments, "item-1", :phase], :review)
        |> put_in([:assignments, "item-1", :board_state], :review)
        |> put_in([:assignments, "item-1", :revision], 2)

      %{state | managed: %{state.managed | data: data}}
    end)

    args = %{assignment_id: "item-1", expected_revision: 2, disposition: "accepted", evidence: ["receipt"]}

    assert {:ok, %{operation: :review, phase: :accepted}} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "review-1", operation: :review, args: args})

    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.assignments["item-1"].phase == :accepted

    assert {:ok, events} = Control.events(pid, 0, 100)
    operations = Enum.map(events, & &1.operation)
    assert :review_intent in operations
    assert :reconcile in operations
    assert :review in operations
    assert :review_committed in operations
  end

  test "context-needed WAITING acceptance requires current fences and a reconciled inactive process" do
    {pid, _path} = managed_server()
    review_observer = self()
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind-waiting-review", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll-waiting-review", operation: :enroll, args: enrollment_args()})

    :sys.replace_state(pid, fn state ->
      assignment =
        Map.merge(state.managed.data.assignments["item-1"], %{
          phase: :waiting,
          board_state: :waiting,
          revision: 2,
          generation: 1,
          attempt_id: "attempt-context",
          worker_active: false,
          stop_pending: true,
          review_observer: review_observer,
          pending_effect: %{kind: :provider_transition, target: :waiting, status: :reconciled},
          last_report: %{
            kind: "context_needed",
            attempt_id: "attempt-context",
            report_id: "context-1",
            summary: "Need PM evidence",
            evidence: []
          }
        })

      data = put_in(state.managed.data, [:assignments, "item-1"], assignment)
      %{state | managed: %{state.managed | data: data}}
    end)

    args = %{
      assignment_id: "item-1",
      expected_revision: 2,
      disposition: "accepted",
      evidence: ["PM verified the requested context"]
    }

    assert {:error, :managed_process_not_inactive_reconciled, %{process_state: :unknown}} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{
               request_id: "review-stop-unknown",
               operation: :review,
               args: args
             })

    refute_receive :managed_review_effect_called

    :sys.replace_state(pid, fn state ->
      data = put_in(state.managed.data, [:assignments, "item-1", :stop_pending], false)
      %{state | managed: %{state.managed | data: data}}
    end)

    active_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(active_pid), do: Process.exit(active_pid, :kill) end)

    :sys.replace_state(pid, fn state ->
      %{state | running: Map.put(state.running, "item-1", %{pid: active_pid})}
    end)

    assert {:error, :managed_process_not_inactive_reconciled, %{process_state: :active}} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{
               request_id: "review-active-process",
               operation: :review,
               args: args
             })

    refute_receive :managed_review_effect_called
    :sys.replace_state(pid, fn state -> %{state | running: Map.delete(state.running, "item-1")} end)
    Process.exit(active_pid, :kill)

    assert {:error, :evidence_required, %{}} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{
               request_id: "review-missing-evidence",
               operation: :review,
               args: %{args | evidence: []}
             })

    assert {:error, :stale_revision, %{expected: 1, actual: 2}} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{
               request_id: "review-stale-revision",
               operation: :review,
               args: %{args | expected_revision: 1}
             })

    wrong_owner = %{principal_id: "00000000-0000-4000-8000-000000000099", role: :pm, project_scope: :all}

    wrong_owner_request =
      SymphonyElixir.ManagedOrchestratorTestControl.envelope(%{
        request_id: "review-wrong-owner",
        operation: :review,
        args: args
      })

    assert {:error, :ownership_conflict, _details} =
             Control.submit_authorized(pid, wrong_owner_request, wrong_owner)

    refute_receive :managed_review_effect_called

    assert {:ok, %{phase: :accepted, issue_close: :ok}} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{
               request_id: "review-context-accepted",
               operation: :review,
               args: args
             })

    assert_receive :managed_review_effect_called
    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.assignments["item-1"].phase == :accepted
  end

  test "managed callbacks fence stale attempts, reserve turns, and retain review reports" do
    {pid, _path} = managed_server()
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    attempt = %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-1"}

    :sys.replace_state(pid, fn state ->
      data =
        put_in(
          state.managed.data,
          [:assignments, "item-1"],
          Map.merge(state.managed.data.assignments["item-1"], %{
            phase: :active,
            board_state: :active,
            generation: 1,
            attempt_id: "attempt-1",
            turn_limit: 2,
            turns_reserved: 0
          })
        )

      %{state | managed: %{state.managed | data: data}}
    end)

    assert :allow = GenServer.call(pid, {:managed_before_turn, %{attempt: attempt}})
    assert :allow = GenServer.call(pid, {:managed_before_turn, %{attempt: attempt}})

    assert {:stop, :managed_turn_budget_exhausted} =
             GenServer.call(pid, {:managed_before_turn, %{attempt: attempt}})

    assert {:error, {:stale_managed_attempt, %{}}} =
             GenServer.call(pid, {:managed_report, %{attempt: %{attempt | generation: 2}, kind: "result", report_id: "r1", summary: "done", evidence: []}})

    assert :ok =
             GenServer.call(pid, {:managed_report, %{attempt: attempt, kind: "result", report_id: "r1", summary: "done", evidence: []}})

    assert :ok =
             GenServer.call(pid, {:managed_report, %{attempt: attempt, kind: "result", report_id: "r1", summary: "done", evidence: []}})

    assert {:ok, snapshot} = Control.state(pid)
    assignment = snapshot.assignments["item-1"]
    assert assignment.phase == :review
    assert assignment.turns_reserved == 2
    assert assignment.last_report.report_id == "r1"
    assert assignment.last_report.summary == "done"
  end

  test "managed run options use the assignment lifetime budget without the default twenty-turn ceiling" do
    {pid, _path} = managed_server()
    issue = %Issue{id: "item-1", identifier: "acme/example#5", state: "ACTIVE"}

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind-budget", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll-budget", operation: :enroll, args: enrollment_args()})

    :sys.replace_state(pid, fn state ->
      assignment =
        state.managed.data.assignments["item-1"]
        |> Map.merge(%{
          revision: 1,
          generation: 1,
          attempt_id: "attempt-budget",
          turn_limit: 30,
          turns_reserved: 0
        })

      put_in(state.managed.data.assignments["item-1"], assignment)
    end)

    state = :sys.get_state(pid)
    options = Orchestrator.managed_run_options_for_test(state, issue)
    assert options[:max_turns] == 30
    assert options[:remaining_turns] == 30

    :sys.replace_state(pid, fn current ->
      put_in(current.managed.data.assignments["item-1"].turns_reserved, 20)
    end)

    options = pid |> :sys.get_state() |> Orchestrator.managed_run_options_for_test(issue)
    assert options[:max_turns] == 30
    assert options[:remaining_turns] == 10

    :sys.replace_state(pid, fn current ->
      put_in(current.managed.data.assignments["item-1"].turns_reserved, 30)
    end)

    options = pid |> :sys.get_state() |> Orchestrator.managed_run_options_for_test(issue)
    assert options[:max_turns] == 30
    assert options[:remaining_turns] == 0
  end

  test "managed reports are idempotent per attempt and local report id" do
    {pid, _path} = managed_server()
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind-reports", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll-reports", operation: :enroll, args: enrollment_args()})

    attempt_one = %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-1"}

    :sys.replace_state(pid, fn state ->
      data =
        put_in(
          state.managed.data,
          [:assignments, "item-1"],
          Map.merge(state.managed.data.assignments["item-1"], %{
            phase: :active,
            board_state: :active,
            generation: 1,
            attempt_id: "attempt-1"
          })
        )

      %{state | managed: %{state.managed | data: data}}
    end)

    first = %{attempt: attempt_one, kind: "result", report_id: "r1", summary: "first result", evidence: ["a"]}
    assert :ok = GenServer.call(pid, {:managed_report, first})
    assert :ok = GenServer.call(pid, {:managed_report, first})

    attempt_two = %{attempt_one | generation: 2, attempt_id: "attempt-2"}

    :sys.replace_state(pid, fn state ->
      data =
        update_in(state.managed.data, [:assignments, "item-1"], fn assignment ->
          Map.merge(assignment, %{phase: :active, board_state: :active, generation: 2, attempt_id: "attempt-2"})
        end)

      %{state | managed: %{state.managed | data: data}}
    end)

    second = %{attempt: attempt_two, kind: "result", report_id: "r1", summary: "second result", evidence: ["b"]}
    assert :ok = GenServer.call(pid, {:managed_report, second})
    assert :ok = GenServer.call(pid, {:managed_report, second})

    assert {:error, {:report_id_conflict, %{attempt_id: "attempt-2", report_id: "r1"}}} =
             GenServer.call(pid, {:managed_report, %{second | summary: "changed"}})

    assert {:ok, snapshot} = Control.state(pid)
    reports = snapshot.assignments["item-1"].reports
    assert map_size(reports) == 2
    assert snapshot.assignments["item-1"].last_report.attempt_id == "attempt-2"
    assert snapshot.assignments["item-1"].last_report.summary == "second result"
  end

  test "stale managed worker telemetry cannot charge its replacement attempt" do
    {pid, _path} = managed_server()
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind-stale-telemetry", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll-stale-telemetry", operation: :enroll, args: enrollment_args()})

    current_attempt = %{assignment_id: "item-1", revision: 1, generation: 2, attempt_id: "attempt-2"}
    stale_attempt = %{current_attempt | generation: 1, attempt_id: "attempt-1"}
    fake_pid = spawn(fn -> Process.sleep(:infinity) end)

    :sys.replace_state(pid, fn state ->
      assignment =
        state.managed.data.assignments["item-1"]
        |> Map.merge(%{phase: :active, board_state: :active, generation: 2, attempt_id: "attempt-2"})
        |> Usage.start_source("thread-2", "attempt-2")

      data = put_in(state.managed.data, [:assignments, "item-1"], assignment)

      running = %{
        pid: fake_pid,
        ref: make_ref(),
        session_id: nil,
        managed_attempt: current_attempt,
        managed_usage_source_thread_id: "thread-2",
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0
      }

      %{state | managed: %{state.managed | data: data}, running: %{"item-1" => running}}
    end)

    send(pid, {:codex_worker_update, "item-1", managed_usage_update(stale_attempt, 100, 20, 120)})
    assert {:ok, stale_snapshot} = Control.state(pid)
    assert stale_snapshot.assignments["item-1"][:usage] == nil

    send(pid, {:codex_worker_update, "item-1", managed_usage_update(current_attempt, 100, 20, 120)})
    assert {:ok, current_snapshot} = Control.state(pid)
    assert current_snapshot.assignments["item-1"].usage.total_tokens == 120
    assert current_snapshot.usage.cumulative_tokens == 120

    Process.exit(fake_pid, :kill)
  end

  test "managed usage retries from the durable source watermark after a journal failure" do
    {pid, _path} = managed_server()
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind-durable-telemetry", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll-durable-telemetry", operation: :enroll, args: enrollment_args()})

    attempt = %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-1"}
    fake_pid = spawn(fn -> Process.sleep(:infinity) end)
    state = :sys.get_state(pid)
    durable_journal = state.managed.journal

    :sys.replace_state(pid, fn state ->
      assignment =
        state.managed.data.assignments["item-1"]
        |> Map.merge(%{phase: :active, board_state: :active, generation: 1, attempt_id: "attempt-1"})
        |> Usage.start_source("thread-1", "attempt-1")

      data = put_in(state.managed.data, [:assignments, "item-1"], assignment)

      running = %{
        pid: fake_pid,
        ref: make_ref(),
        session_id: nil,
        managed_attempt: attempt,
        managed_usage_source_thread_id: "thread-1",
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0
      }

      %{
        state
        | managed: %{state.managed | data: data, journal: %{name: :missing_managed_usage_journal}},
          running: %{"item-1" => running}
      }
    end)

    send(pid, {:codex_worker_update, "item-1", managed_usage_update(attempt, 100, 20, 120)})
    assert {:ok, failed_snapshot} = Control.state(pid)
    assert failed_snapshot.assignments["item-1"][:usage] == nil
    assert :sys.get_state(pid).running["item-1"].codex_last_reported_total_tokens == 120

    :sys.replace_state(pid, fn state -> %{state | managed: %{state.managed | journal: durable_journal}} end)

    send(pid, {:codex_worker_update, "item-1", managed_usage_update(attempt, 125, 25, 150)})
    assert {:ok, recovered_snapshot} = Control.state(pid)
    assert recovered_snapshot.assignments["item-1"].usage.total_tokens == 150
    assert recovered_snapshot.usage.cumulative_tokens == 150

    Process.exit(fake_pid, :kill)
  end

  test "service reconciliation supplies review facts while caller fields are ignored" do
    {pid, _path} = managed_server()
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    :sys.replace_state(pid, fn state ->
      data =
        put_in(
          state.managed.data,
          [:assignments, "item-1"],
          Map.merge(state.managed.data.assignments["item-1"], %{phase: :review, board_state: :review})
        )

      %{state | managed: %{state.managed | data: data}}
    end)

    assert {:ok, _} =
             Control.reconcile(pid, "item-1", %{
               revision: 1,
               provider_state: "REVIEW",
               reconciled: true,
               external_effects: %{status: "ok", issue_close: "ok"}
             })

    assert {:ok, response} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{
               request_id: "review",
               operation: :review,
               args: %{
                 assignment_id: "item-1",
                 expected_revision: 1,
                 disposition: "accepted",
                 evidence: ["test"],
                 provider_state: "ACTIVE",
                 reconciled: false
               }
             })

    assert response.phase == :accepted
  end
end

defmodule SymphonyElixir.ManagedOrchestratorDeferredReportTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.{Control, Journal, Rules}

  defp binding_args do
    %{
      expected_revision: 0,
      project: %{
        project_id: "PVT_test",
        project_number: 4,
        status_field_id: "PVTSSF_test",
        status_options: %{
          "READY" => "ready",
          "ACTIVE" => "active",
          "REVIEW" => "review",
          "ACCEPTED" => "accepted",
          "WAITING" => "waiting",
          "CANCELLED" => "cancelled"
        },
        repositories: ["acme/example"]
      }
    }
  end

  defp enrollment_args do
    %{
      expected_revision: 1,
      assignment_id: "item-1",
      repository: "acme/example",
      issue_number: 5,
      base_commit: "base",
      board_state: "READY",
      resources: [%{kind: :repository, authority: "github.com", identity: "acme/example", access: :write}],
      dependencies: [],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"}
    }
  end

  test "context-needed reports defer WAITING provider effect until the worker DOWN" do
    name = Module.concat(__MODULE__, :"server_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "managed-deferred-#{System.unique_integer([:positive])}.log")
    {:ok, pid} = Orchestrator.start_link(name: name, managed_effects: SymphonyElixir.ManagedDeferredTransitionStub)
    {:ok, journal, %{}} = Journal.open(path, name: String.to_atom("managed_deferred_#{System.unique_integer([:positive])}"))

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{journal: journal, data: Rules.new(), effects: SymphonyElixir.ManagedDeferredTransitionStub}, poll_check_in_progress: true}
    end)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    attempt = %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-1"}
    fake_pid = spawn(fn -> Process.sleep(:infinity) end)

    ref = make_ref()

    :sys.replace_state(pid, fn state ->
      data =
        put_in(
          state.managed.data,
          [:assignments, "item-1"],
          Map.merge(state.managed.data.assignments["item-1"], %{
            phase: :active,
            board_state: :active,
            generation: 1,
            attempt_id: "attempt-1",
            turn_limit: 2,
            turns_reserved: 0
          })
        )

      running = %{
        pid: fake_pid,
        ref: ref,
        issue: %SymphonyElixir.Tracker.Issue{id: "item-1", identifier: "acme/example#5", url: "https://example.test/item-1"},
        identifier: "acme/example#5",
        session_id: nil,
        worker_host: nil,
        workspace_path: nil,
        managed_attempt: attempt,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        started_at: DateTime.utc_now()
      }

      %{state | managed: %{state.managed | data: data}, running: %{"item-1" => running}}
    end)

    assert :ok =
             GenServer.call(pid, {:managed_report, %{attempt: attempt, kind: "context_needed", report_id: "block-1", summary: "need access", evidence: []}})

    assert {:ok, pending_snapshot} = Control.state(pid)
    assert pending_snapshot.assignments["item-1"].phase == :waiting
    assert pending_snapshot.assignments["item-1"].stop_pending == true

    assert {:ok, events} = Control.events(pid, 0, 100)
    assert Enum.any?(events, &(&1.operation == :provider_transition_deferred))

    send(pid, {:DOWN, ref, :process, fake_pid, {:managed_agent_terminal, %{kind: "context_needed"}}})
    _ = Control.state(pid)

    assert {:ok, final_snapshot} = Control.state(pid)
    assert final_snapshot.assignments["item-1"].phase == :waiting
    assert final_snapshot.assignments["item-1"].pending_effect.status == :reconciled
    assert final_snapshot.assignments["item-1"].stop_pending == false

    state = :sys.get_state(pid)
    assert state.managed.data.effect_intents |> Map.values() |> Enum.any?(&(&1.status == :effect_reconciled))
    Process.exit(fake_pid, :kill)
  end

  test "operator interrupt commits WAITING after the owned worker confirms DOWN" do
    name = Module.concat(__MODULE__, :"server_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "managed-interrupt-#{System.unique_integer([:positive])}.log")
    {:ok, pid} = Orchestrator.start_link(name: name, managed_effects: SymphonyElixir.ManagedDeferredTransitionStub)
    {:ok, journal, %{}} = Journal.open(path, name: String.to_atom("managed_interrupt_#{System.unique_integer([:positive])}"))

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{journal: journal, data: Rules.new(), effects: SymphonyElixir.ManagedDeferredTransitionStub}, poll_check_in_progress: true}
    end)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    attempt = %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-1"}
    parent = self()

    fake_pid =
      spawn(fn ->
        receive do
          message ->
            send(parent, {:worker_control, message})
            Process.sleep(:infinity)
        end
      end)

    ref = make_ref()

    :sys.replace_state(pid, fn state ->
      data =
        put_in(
          state.managed.data,
          [:assignments, "item-1"],
          Map.merge(state.managed.data.assignments["item-1"], %{
            phase: :active,
            board_state: :active,
            generation: 1,
            attempt_id: "attempt-1"
          })
        )

      running = %{
        pid: fake_pid,
        ref: ref,
        issue: %SymphonyElixir.Tracker.Issue{id: "item-1", identifier: "acme/example#5", url: "https://example.test/item-1"},
        identifier: "acme/example#5",
        session_id: nil,
        worker_host: nil,
        workspace_path: nil,
        managed_attempt: attempt,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        started_at: DateTime.utc_now()
      }

      %{state | managed: %{state.managed | data: data}, running: %{"item-1" => running}}
    end)

    assert {:ok, pending} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{
               request_id: "interrupt-1",
               operation: :interrupt,
               args: %{
                 assignment_id: "item-1",
                 expected_revision: 1,
                 project_id: "PVT_test",
                 expected_ownership_revision: 1,
                 reason: "operator stop"
               }
             })

    assert pending.pending == true
    assert pending.stop_pending == true
    assert_receive {:worker_control, {:symphony_stop, :managed_stop_pending}}, 1_000

    send(pid, {:DOWN, ref, :process, fake_pid, {:managed_agent_guard_stop, :managed_stop_pending}})
    _ = Control.state(pid)

    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.assignments["item-1"].phase == :waiting
    assert snapshot.assignments["item-1"].board_state == :waiting
    assert snapshot.assignments["item-1"].stop_pending == false

    state = :sys.get_state(pid)
    assert state.managed.data.effect_intents["interrupt-1"].status == :committed
    refute Map.has_key?(state.retry_attempts, "item-1")
    Process.exit(fake_pid, :kill)
  end
end

defmodule SymphonyElixir.ManagedOrchestratorRecoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.{Control, Journal, Rules}

  defp binding_args do
    %{
      expected_revision: 0,
      project: %{
        project_id: "PVT_test",
        project_number: 4,
        status_field_id: "PVTSSF_test",
        status_options: %{
          "READY" => "ready",
          "ACTIVE" => "active",
          "REVIEW" => "review",
          "ACCEPTED" => "accepted",
          "WAITING" => "waiting",
          "CANCELLED" => "cancelled"
        },
        repositories: ["acme/example"]
      }
    }
  end

  defp enrollment_args do
    %{
      expected_revision: 1,
      assignment_id: "item-1",
      repository: "acme/example",
      issue_number: 5,
      base_commit: "base",
      board_state: "READY",
      resources: [%{kind: :repository, authority: "github.com", identity: "acme/example", access: :write}],
      dependencies: [],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"}
    }
  end

  defp managed_server do
    name = Module.concat(__MODULE__, :"server_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "managed-orchestrator-#{System.unique_integer([:positive])}.log")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        managed_effects: SymphonyElixir.ManagedReviewEffectsStub,
        schedule_initial_tick: false
      )

    {:ok, journal, %{}} = Journal.open(path, name: String.to_atom("managed_test_#{System.unique_integer([:positive])}"))

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{journal: journal, data: Rules.new(), effects: SymphonyElixir.ManagedReviewEffectsStub}, poll_check_in_progress: true}
    end)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    {pid, path}
  end

  test "poll recovery waits for a managed worker stop before replaying an explicit transition" do
    {pid, _path} = managed_server()

    assert {:ok, _} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{
               request_id: "bind",
               operation: :bind_project,
               args: binding_args()
             })

    assert {:ok, _} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{
               request_id: "enroll",
               operation: :enroll,
               args: enrollment_args()
             })

    parent = self()

    fake_pid =
      spawn(fn ->
        receive do
          message ->
            send(parent, {:worker_control, message})
            Process.sleep(:infinity)
        end
      end)

    on_exit(fn -> if Process.alive?(fake_pid), do: Process.exit(fake_pid, :kill) end)
    ref = make_ref()
    attempt = %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-1"}

    :sys.replace_state(pid, fn state ->
      assignment =
        Map.merge(state.managed.data.assignments["item-1"], %{
          phase: :review,
          board_state: :review,
          generation: 1,
          attempt_id: "attempt-1",
          transition_observer: parent
        })

      running = %{
        pid: fake_pid,
        ref: ref,
        issue: %SymphonyElixir.Tracker.Issue{id: "item-1", identifier: "acme/example#5"},
        identifier: "acme/example#5",
        session_id: nil,
        worker_host: nil,
        workspace_path: nil,
        managed_attempt: attempt,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        started_at: DateTime.utc_now()
      }

      data = put_in(state.managed.data, [:assignments, "item-1"], assignment)

      %{
        state
        | managed: %{state.managed | data: data, effects: SymphonyElixir.ManagedCountingTransitionStub},
          running: %{"item-1" => running}
      }
    end)

    assert {:ok, %{pending: true, stop_pending: true}} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{
               request_id: "review-rework-running",
               operation: :review,
               args: %{
                 project_id: "PVT_test",
                 assignment_id: "item-1",
                 expected_revision: 1,
                 expected_ownership_revision: 1,
                 disposition: :rework,
                 reason: "apply revision after the worker stops"
               }
             })

    assert_receive {:worker_control, {:symphony_stop, :managed_stop_pending}}, 1_000

    recovered = Orchestrator.recover_managed_transitions_for_test(:sys.get_state(pid))
    refute_receive {:managed_transition_effect, "item-1", :ready}, 100
    assert recovered.managed.data.effect_intents["review-rework-running"].status == :pending
    assert recovered.managed.data.assignments["item-1"].phase == :review
    assert recovered.managed.data.assignments["item-1"].stop_pending == true
    :sys.replace_state(pid, fn _ -> recovered end)

    send(pid, {:DOWN, ref, :process, fake_pid, {:managed_agent_guard_stop, :managed_stop_pending}})
    assert {:ok, snapshot} = Control.state(pid)
    assert_receive {:managed_transition_effect, "item-1", :ready}, 1_000
    assert snapshot.assignments["item-1"].phase == :ready
    assert snapshot.assignments["item-1"].stop_pending == false
    assert :sys.get_state(pid).managed.data.effect_intents["review-rework-running"].status == :committed
  end

  test "startup recovery replays automatic provider intents with no control request" do
    name = Module.concat(__MODULE__, :"server_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "managed-recovery-#{System.unique_integer([:positive])}.log")
    {:ok, pid} = Orchestrator.start_link(name: name, managed_effects: SymphonyElixir.ManagedReviewEffectsStub)
    {:ok, journal, %{}} = Journal.open(path, name: String.to_atom("managed_recovery_#{System.unique_integer([:positive])}"))

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{journal: journal, data: Rules.new(), effects: SymphonyElixir.ManagedReviewEffectsStub}, poll_check_in_progress: true}
    end)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    state = :sys.get_state(pid)

    data =
      state.managed.data
      |> put_in([:assignments, "item-1", :phase], :ready)
      |> put_in([:assignments, "item-1", :board_state], :ready)
      |> put_in([:effect_intents, "auto-ready"], %{
        request_id: "auto-ready",
        request: nil,
        binding: state.managed.data.projects["PVT_test"],
        assignment_id: "item-1",
        target: :ready,
        status: :pending
      })

    recovered = Orchestrator.recover_managed_transitions_for_test(%{state | managed: %{state.managed | data: data}})
    :sys.replace_state(pid, fn _ -> recovered end)

    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.assignments["item-1"].pending_effect.status == :reconciled

    state = :sys.get_state(pid)
    assert state.managed.data.effect_intents["auto-ready"].status == :effect_reconciled
  end

  test "startup recovery does not replay completed automatic transitions and creates a fresh intent" do
    name = Module.concat(__MODULE__, :recovery_once)
    path = Path.join(System.tmp_dir!(), "managed-recovery-once-#{System.unique_integer([:positive])}.log")
    {:ok, pid} = Orchestrator.start_link(name: name, managed_effects: SymphonyElixir.ManagedCountingTransitionStub)
    {:ok, journal, %{}} = Journal.open(path, name: String.to_atom("managed_recovery_once_#{System.unique_integer([:positive])}"))

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{journal: journal, data: Rules.new(), effects: SymphonyElixir.ManagedCountingTransitionStub}, poll_check_in_progress: true}
    end)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    state = :sys.get_state(pid)

    data =
      state.managed.data
      |> update_in([:assignments, "item-1"], &Map.merge(&1, %{transition_observer: self()}))
      |> put_in([:effect_intents, "auto-active"], %{
        request_id: "auto-active",
        request: nil,
        binding: state.managed.data.projects["PVT_test"],
        assignment_id: "item-1",
        target: :active,
        status: :pending
      })

    recovered = Orchestrator.recover_managed_transitions_for_test(%{state | managed: %{state.managed | data: data}})
    assert_receive {:managed_transition_effect, "item-1", :active}
    assert recovered.managed.data.effect_intents["auto-active"].status == :effect_reconciled

    data =
      recovered.managed.data
      |> update_in([:assignments, "item-1"], &Map.merge(&1, %{phase: :active, board_state: :active}))
      |> put_in([:effect_intents, "auto-ready"], %{
        request_id: "auto-ready",
        request: nil,
        binding: state.managed.data.projects["PVT_test"],
        assignment_id: "item-1",
        target: :ready,
        status: :pending
      })

    recovered =
      Orchestrator.recover_managed_transitions_for_test(%{
        recovered
        | managed: %{recovered.managed | data: data}
      })

    assert_receive {:managed_transition_effect, "item-1", :ready}
    assert recovered.managed.data.effect_intents["auto-ready"].status == :effect_reconciled

    event_cursor = recovered.managed.data.event_cursor
    events = recovered.managed.data.events
    recovered_again = Orchestrator.recover_managed_transitions_for_test(recovered)
    refute_receive {:managed_transition_effect, "item-1", _target}, 100
    assert recovered_again.managed.data.event_cursor == event_cursor
    assert recovered_again.managed.data.events == events

    :sys.replace_state(pid, fn _ -> recovered_again end)
    fake_pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(fake_pid), do: Process.exit(fake_pid, :kill) end)
    ref = make_ref()

    :sys.replace_state(pid, fn state ->
      assignment =
        Map.merge(state.managed.data.assignments["item-1"], %{
          phase: :active,
          board_state: :active,
          attempt_id: "attempt-2",
          generation: 1,
          turns_reserved: 0,
          retry_count: 0
        })

      running = %{
        pid: fake_pid,
        ref: ref,
        managed_attempt: %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-2"},
        session_id: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        started_at: DateTime.utc_now()
      }

      %{
        state
        | managed: %{state.managed | data: put_in(state.managed.data, [:assignments, "item-1"], assignment)},
          running: %{"item-1" => running}
      }
    end)

    send(pid, {:DOWN, ref, :process, fake_pid, {:managed_agent_failed, :spawn_failed}})
    _ = Control.state(pid)
    assert_receive {:managed_transition_effect, "item-1", :ready}

    state = :sys.get_state(pid)

    ready_intents =
      state.managed.data.effect_intents
      |> Enum.filter(fn {_id, intent} -> intent[:target] == :ready and is_nil(intent[:request]) end)

    assert length(ready_intents) == 2
    assert Enum.any?(ready_intents, fn {id, _intent} -> id != "auto-ready" end)
    Process.exit(fake_pid, :kill)
  end

  defp body_fingerprint(body) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end

  defp revision_server do
    {pid, path} = managed_server()

    :sys.replace_state(pid, fn state ->
      data = %{state.managed.data | disabled: true}
      managed = %{state.managed | data: data, effects: SymphonyElixir.ManagedRequirementsTransitionStub}
      %{state | managed: managed}
    end)

    {pid, path}
  end

  defp stop_revision_polling(pid) do
    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      %{
        state
        | tick_timer_ref: nil,
          tick_token: nil,
          poll_interval_ms: :timer.hours(1),
          poll_check_in_progress: false
      }
    end)
  end

  defp prepare_revision_assignment(pid, old_fingerprint, new_fingerprint) do
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})

    enrollment =
      enrollment_args()
      |> Map.put(:requirements_fingerprint, old_fingerprint)
      |> Map.put(:requirements_revision, 1)

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment})
    observer = self()

    :sys.replace_state(pid, fn state ->
      data =
        update_in(state.managed.data, [:assignments, "item-1"], fn assignment ->
          Map.merge(assignment, %{
            transition_observer: observer,
            expected_requirements_fingerprint: new_fingerprint
          })
        end)

      %{state | managed: %{state.managed | data: data}}
    end)

    stop_revision_polling(pid)
  end

  defp revise_request(request_id, expected_revision, fingerprint) do
    %{
      request_id: request_id,
      operation: :revise,
      args: %{
        assignment_id: "item-1",
        expected_revision: expected_revision,
        project_id: "PVT_test",
        expected_ownership_revision: 1,
        changes: %{requirements_fingerprint: fingerprint, requirements_revision: 2}
      }
    }
  end

  for {disposition, target} <- [{:rework, :ready}, {:waiting, :waiting}] do
    @review_disposition disposition
    @review_target target
    test "deferred review reconciles the provider before committing #{@review_disposition}" do
      fingerprint = body_fingerprint("unchanged-requirements")
      {pid, _path} = revision_server()
      prepare_revision_assignment(pid, fingerprint, fingerprint)

      :sys.replace_state(pid, fn state ->
        data = update_in(state.managed.data, [:assignments, "item-1"], &Map.merge(&1, %{phase: :review, board_state: :review, stop_pending: true}))
        %{state | managed: %{state.managed | data: data}}
      end)

      request = %{
        request_id: "deferred-review",
        operation: :review,
        args: %{assignment_id: "item-1", expected_revision: 1, disposition: @review_disposition, reason: "Continue retained work"}
      }

      assert {:ok, response} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, request)
      assert_receive {:requirements_transition_target, @review_target, _assignment}
      assert response.phase == @review_target
      state = :sys.get_state(pid).managed.data
      assert state.effect_intents["deferred-review"].status == :committed
      assert state.assignments["item-1"].stop_pending == false
      assert state.assignments["item-1"].pending_effect.facts.provider_state == @review_target
      assert {:ok, %{duplicate: true}} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, request)
      refute_receive {:requirements_transition_target, _, _}, 100
    end
  end

  test "rework provider failure preserves the prior phase and durable recovery intent" do
    {pid, _path} = revision_server()
    prepare_revision_assignment(pid, body_fingerprint("old"), body_fingerprint("changed"))

    :sys.replace_state(pid, fn state ->
      data = update_in(state.managed.data, [:assignments, "item-1"], &Map.merge(&1, %{phase: :waiting, board_state: :waiting, stop_pending: true}))
      %{state | managed: %{state.managed | data: data}}
    end)

    request = %{
      request_id: "failed-rework",
      operation: :review,
      args: %{assignment_id: "item-1", expected_revision: 1, disposition: :rework, reason: "Continue retained work"}
    }

    assert {:error, {:requirements_changed, _}} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, request)
    state = :sys.get_state(pid).managed.data
    assert state.assignments["item-1"].phase == :waiting
    assert state.assignments["item-1"].revision == 1
    assert state.effect_intents["failed-rework"].status == :pending
    assert state.assignments["item-1"].stop_pending == true
  end

  test "fresh revise control verifies new requirements before committing locally" do
    old_fingerprint = body_fingerprint("requirements-v1")
    new_fingerprint = body_fingerprint("requirements-v2")
    {pid, _path} = revision_server()
    prepare_revision_assignment(pid, old_fingerprint, new_fingerprint)

    request = revise_request("revise-r2", 1, new_fingerprint)
    assert {:ok, response} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, request)
    assert response.revision == 2
    assert_receive {:requirements_transition, provider_assignment}
    assert provider_assignment.requirements_fingerprint == new_fingerprint
    assert provider_assignment.requirements_revision == 2

    state = :sys.get_state(pid)
    assignment = state.managed.data.assignments["item-1"]
    assert assignment.requirements_fingerprint == new_fingerprint
    assert assignment.requirements_revision == 2
    assert assignment.revision == 2
    assert state.managed.data.effect_intents["revise-r2"].status == :committed

    event_cursor = state.managed.data.event_cursor
    assert {:ok, duplicate} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, request)
    assert duplicate.duplicate == true
    refute_receive {:requirements_transition, _assignment}, 100
    assert :sys.get_state(pid).managed.data.event_cursor == event_cursor
  end

  test "pending revise recovery supplies new requirements and commits after the provider effect" do
    old_fingerprint = body_fingerprint("requirements-v1")
    new_fingerprint = body_fingerprint("requirements-v2")
    {pid, _path} = revision_server()
    prepare_revision_assignment(pid, old_fingerprint, new_fingerprint)
    assert {:ok, _snapshot} = Control.state(pid)

    request = revise_request("revise-recovered-r2", 1, new_fingerprint)
    state = :sys.get_state(pid)

    data =
      state.managed.data
      |> update_in([:assignments, "item-1"], &Map.merge(&1, %{phase: :active, board_state: :active, stop_pending: true}))
      |> put_in([:effect_intents, "revise-recovered-r2"], %{
        request_id: "revise-recovered-r2",
        request: request,
        binding: state.managed.data.projects["PVT_test"],
        principal_context: SymphonyElixir.ManagedOrchestratorTestControl.principal(),
        assignment_id: "item-1",
        target: :ready,
        context: Map.put(SymphonyElixir.ManagedOrchestratorTestControl.principal(), :stop_reconciled, true),
        status: :pending
      })

    :sys.replace_state(pid, fn current -> %{current | managed: %{current.managed | data: data}} end)
    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.assignments["item-1"].requirements_fingerprint == old_fingerprint
    assert snapshot.assignments["item-1"].requirements_revision == 1
    assert snapshot.assignments["item-1"].revision == 1

    recovered = Orchestrator.recover_managed_transitions_for_test(:sys.get_state(pid))
    assert_receive {:requirements_transition, provider_assignment}
    assert provider_assignment.requirements_fingerprint == new_fingerprint
    assert provider_assignment.requirements_revision == 2
    :sys.replace_state(pid, fn _ -> recovered end)

    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.assignments["item-1"].requirements_fingerprint == new_fingerprint
    assert snapshot.assignments["item-1"].requirements_revision == 2
    assert snapshot.assignments["item-1"].revision == 2
    assert snapshot.assignments["item-1"].stop_pending == false
    assert :sys.get_state(pid).managed.data.effect_intents["revise-recovered-r2"].status == :committed
  end

  test "pending revise with changed input rejects the request without provider effects" do
    old_fingerprint = body_fingerprint("requirements-v1")
    new_fingerprint = body_fingerprint("requirements-v2")
    wrong_fingerprint = body_fingerprint("requirements-wrong")
    {pid, _path} = revision_server()
    prepare_revision_assignment(pid, old_fingerprint, new_fingerprint)
    assert {:ok, _snapshot} = Control.state(pid)

    pending_request = revise_request("revise-pending-r2", 1, new_fingerprint)
    state = :sys.get_state(pid)

    data =
      put_in(state.managed.data, [:effect_intents, "revise-pending-r2"], %{
        request_id: "revise-pending-r2",
        request: pending_request,
        binding: state.managed.data.projects["PVT_test"],
        principal_context: SymphonyElixir.ManagedOrchestratorTestControl.principal(),
        assignment_id: "item-1",
        target: :ready,
        context: Map.put(SymphonyElixir.ManagedOrchestratorTestControl.principal(), :stop_reconciled, true),
        status: :pending
      })

    :sys.replace_state(pid, fn current -> %{current | managed: %{current.managed | data: data}} end)
    event_cursor = state.managed.data.event_cursor
    changed_request = revise_request("revise-pending-r2", 1, wrong_fingerprint)

    assert {:error, :request_id_conflict, _details} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, changed_request)
    refute_receive {:requirements_transition, _assignment}, 100
    refute_receive {:requirements_transition_rejected, _assignment}, 100

    state = :sys.get_state(pid)
    assert state.managed.data.event_cursor == event_cursor
    assert state.managed.data.effect_intents["revise-pending-r2"].request == pending_request
    assert state.managed.data.effect_intents["revise-pending-r2"].status == :pending
    assert state.managed.data.assignments["item-1"].requirements_fingerprint == old_fingerprint
    assert state.managed.data.assignments["item-1"].revision == 1
  end

  test "wrong requirements keep the old assignment after provider rejection" do
    old_fingerprint = body_fingerprint("requirements-v1")
    new_fingerprint = body_fingerprint("requirements-v2")
    wrong_fingerprint = body_fingerprint("requirements-wrong")
    {pid, _path} = revision_server()
    prepare_revision_assignment(pid, old_fingerprint, new_fingerprint)

    assert {:error, _reason} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, revise_request("revise-wrong-r2", 1, wrong_fingerprint))
    assert_receive {:requirements_transition_rejected, provider_assignment}
    assert provider_assignment.requirements_fingerprint == wrong_fingerprint

    state = :sys.get_state(pid)
    assignment = state.managed.data.assignments["item-1"]
    assert assignment.requirements_fingerprint == old_fingerprint
    assert assignment.requirements_revision == 1
    assert assignment.revision == 1
    assert state.managed.data.effect_intents["revise-wrong-r2"].status == :pending
  end

  test "stale revisions are rejected before provider effects" do
    old_fingerprint = body_fingerprint("requirements-v1")
    new_fingerprint = body_fingerprint("requirements-v2")
    {pid, _path} = revision_server()
    prepare_revision_assignment(pid, old_fingerprint, new_fingerprint)
    state = :sys.get_state(pid)
    event_cursor = state.managed.data.event_cursor

    assert {:error, :stale_revision, _details} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, revise_request("revise-stale-r2", 0, new_fingerprint))
    refute_receive {:requirements_transition, _assignment}, 100
    refute_receive {:requirements_transition_rejected, _assignment}, 100

    state = :sys.get_state(pid)
    assert state.managed.data.event_cursor == event_cursor
    refute Map.has_key?(state.managed.data.effect_intents, "revise-stale-r2")
    assert state.managed.data.assignments["item-1"].requirements_fingerprint == old_fingerprint
    assert state.managed.data.assignments["item-1"].revision == 1
  end

  test "successful revision resets exhausted retry state and retires obsolete automatic transitions" do
    old_fingerprint = body_fingerprint("requirements-v1")
    new_fingerprint = body_fingerprint("requirements-v2")
    {pid, _path} = revision_server()
    prepare_revision_assignment(pid, old_fingerprint, new_fingerprint)

    :sys.replace_state(pid, fn current ->
      data = put_in(current.managed.data, [:assignments, "item-1", :turns_reserved], 7)
      %{current | managed: %{current.managed | data: data}}
    end)

    state = :sys.get_state(pid)

    exhausted =
      Enum.reduce(1..3, state, fn generation, current ->
        Orchestrator.mark_managed_dispatch_failed_for_test(
          current,
          "item-1",
          %{assignment_id: "item-1", revision: 1, generation: generation, attempt_id: "failed-#{generation}"},
          :spawn_failed
        )
      end)

    auto_active = %{
      request_id: "auto-active-before-revise",
      request: nil,
      binding: state.managed.data.projects["PVT_test"],
      assignment_id: "item-1",
      target: :active,
      revision: 1,
      auto: true,
      status: :pending
    }

    data = put_in(exhausted.managed.data, [:effect_intents, auto_active.request_id], auto_active)
    :sys.replace_state(pid, fn current -> %{current | managed: %{current.managed | data: data}} end)

    assert {:ok, response} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, revise_request("revise-after-retries", 1, new_fingerprint))
    assert response.revision == 2
    assert_receive {:requirements_transition, provider_assignment}
    assert provider_assignment.requirements_fingerprint == new_fingerprint
    assert_receive {:requirements_transition_target, :ready, ^provider_assignment}
    refute_receive {:requirements_transition_target, :active, _assignment}, 100

    state = :sys.get_state(pid)
    assignment = state.managed.data.assignments["item-1"]
    assert assignment.phase == :ready
    assert assignment.board_state == :ready
    assert assignment.retry_count == 0
    refute Map.has_key?(assignment, :blocked_reason)
    assert assignment.turns_reserved == 7
    assert assignment.turn_limit == 20
    assert state.managed.data.effect_intents[auto_active.request_id].status == :retired
    assert state.managed.data.effect_intents[auto_active.request_id].retired_reason == :assignment_revised

    recovered = Orchestrator.recover_managed_transitions_for_test(state)
    refute_receive {:requirements_transition, _assignment}, 100
    refute_receive {:requirements_transition_rejected, _assignment}, 100
    refute_receive {:managed_transition_effect, "item-1", :active}, 100
    assert recovered.managed.data.assignments["item-1"].phase == :ready
  end

  test "failed revision preserves retry state and uncertain automatic intents" do
    old_fingerprint = body_fingerprint("requirements-v1")
    new_fingerprint = body_fingerprint("requirements-v2")
    wrong_fingerprint = body_fingerprint("requirements-wrong")
    {pid, _path} = revision_server()
    prepare_revision_assignment(pid, old_fingerprint, new_fingerprint)

    state = :sys.get_state(pid)

    exhausted =
      Enum.reduce(1..3, state, fn generation, current ->
        Orchestrator.mark_managed_dispatch_failed_for_test(
          current,
          "item-1",
          %{assignment_id: "item-1", revision: 1, generation: generation, attempt_id: "failed-#{generation}"},
          :spawn_failed
        )
      end)

    auto_active = %{
      request_id: "auto-active-uncertain",
      request: nil,
      binding: state.managed.data.projects["PVT_test"],
      assignment_id: "item-1",
      target: :active,
      revision: 1,
      auto: true,
      status: :pending
    }

    data = put_in(exhausted.managed.data, [:effect_intents, auto_active.request_id], auto_active)
    :sys.replace_state(pid, fn current -> %{current | managed: %{current.managed | data: data}} end)

    assert {:error, {:requirements_changed, _details}} =
             SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, revise_request("revise-failed-after-retries", 1, wrong_fingerprint))

    assert_receive {:requirements_transition_rejected, provider_assignment}
    assert provider_assignment.requirements_fingerprint == wrong_fingerprint

    state = :sys.get_state(pid)
    assignment = state.managed.data.assignments["item-1"]
    assert assignment.phase == :waiting
    assert assignment.retry_count == 3
    assert assignment.blocked_reason == ":spawn_failed"
    assert assignment.requirements_fingerprint == old_fingerprint
    assert assignment.requirements_revision == 1
    assert state.managed.data.effect_intents[auto_active.request_id] == auto_active
  end

  test "pending revision replay rejects a stale request before provider effects" do
    old_fingerprint = body_fingerprint("requirements-v1")
    new_fingerprint = body_fingerprint("requirements-v2")
    {pid, _path} = revision_server()
    prepare_revision_assignment(pid, old_fingerprint, new_fingerprint)
    request = revise_request("revise-pending-stale", 1, new_fingerprint)
    state = :sys.get_state(pid)

    data =
      state.managed.data
      |> put_in([:assignments, "item-1", :revision], 2)
      |> put_in([:effect_intents, request.request_id], %{
        request_id: request.request_id,
        request: request,
        binding: state.managed.data.projects["PVT_test"],
        principal_context: SymphonyElixir.ManagedOrchestratorTestControl.principal(),
        assignment_id: "item-1",
        target: :ready,
        context: Map.put(SymphonyElixir.ManagedOrchestratorTestControl.principal(), :stop_reconciled, true),
        status: :pending
      })

    :sys.replace_state(pid, fn current -> %{current | managed: %{current.managed | data: data}} end)
    assert {:error, {:stale_revision, _details}} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, request)
    refute_receive {:requirements_transition, _assignment}, 100
    refute_receive {:requirements_transition_rejected, _assignment}, 100

    state = :sys.get_state(pid)
    assert state.managed.data.effect_intents[request.request_id].status == :pending
    assert state.managed.data.assignments["item-1"].revision == 2
  end

  test "cold recovery commits a pending revision before replaying obsolete automatic transitions" do
    old_fingerprint = body_fingerprint("requirements-v1")
    new_fingerprint = body_fingerprint("requirements-v2")
    {pid, path} = revision_server()
    prepare_revision_assignment(pid, old_fingerprint, new_fingerprint)
    request = revise_request("revise-cold-recovery", 1, new_fingerprint)
    state = :sys.get_state(pid)

    exhausted =
      Enum.reduce(1..3, state, fn generation, current ->
        Orchestrator.mark_managed_dispatch_failed_for_test(
          current,
          "item-1",
          %{assignment_id: "item-1", revision: 1, generation: generation, attempt_id: "cold-failed-#{generation}"},
          :spawn_failed
        )
      end)

    auto_active = %{
      request_id: "auto-active-cold-recovery",
      request: nil,
      binding: state.managed.data.projects["PVT_test"],
      assignment_id: "item-1",
      target: :active,
      revision: 1,
      auto: true,
      status: :pending
    }

    data =
      exhausted.managed.data
      |> put_in([:effect_intents, auto_active.request_id], auto_active)
      |> put_in([:effect_intents, request.request_id], %{
        request_id: request.request_id,
        request: request,
        binding: state.managed.data.projects["PVT_test"],
        principal_context: SymphonyElixir.ManagedOrchestratorTestControl.principal(),
        assignment_id: "item-1",
        target: :ready,
        context: Map.put(SymphonyElixir.ManagedOrchestratorTestControl.principal(), :stop_reconciled, true),
        status: :pending
      })

    :ok = Journal.append(exhausted.managed.journal, data)
    :ok = GenServer.stop(pid)

    name = Module.concat(__MODULE__, :cold_recovery_restart)

    {:ok, restarted_pid} =
      Orchestrator.start_link(
        name: name,
        managed_effects: SymphonyElixir.ManagedRequirementsTransitionStub,
        schedule_initial_tick: false
      )

    journal_name = String.to_atom("managed_cold_restart_#{System.unique_integer([:positive])}")
    {:ok, journal, loaded} = Journal.open(path, name: journal_name)

    :sys.replace_state(restarted_pid, fn current ->
      managed = %{journal: journal, data: loaded, effects: SymphonyElixir.ManagedRequirementsTransitionStub}
      %{current | managed: managed, poll_check_in_progress: true}
    end)

    on_exit(fn ->
      if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid)
    end)

    recovered = Orchestrator.recover_managed_transitions_for_test(:sys.get_state(restarted_pid))
    assert_receive {:requirements_transition, provider_assignment}
    assert provider_assignment.requirements_fingerprint == new_fingerprint
    assert_receive {:requirements_transition_target, :ready, ^provider_assignment}
    refute_receive {:requirements_transition_target, :active, _assignment}, 100

    :sys.replace_state(restarted_pid, fn _ -> recovered end)
    state = :sys.get_state(restarted_pid)
    assignment = state.managed.data.assignments["item-1"]
    assert assignment.phase == :ready
    assert assignment.retry_count == 0
    refute Map.has_key?(assignment, :blocked_reason)
    assert state.managed.data.effect_intents[auto_active.request_id].status == :retired
  end

  test "stale pending interrupt replay validates before provider effects" do
    old_fingerprint = body_fingerprint("requirements-v1")
    new_fingerprint = body_fingerprint("requirements-v2")
    {pid, _path} = revision_server()
    prepare_revision_assignment(pid, old_fingerprint, new_fingerprint)

    request = %{
      request_id: "interrupt-pending-stale",
      operation: :interrupt,
      args: %{
        assignment_id: "item-1",
        expected_revision: 1,
        project_id: "PVT_test",
        expected_ownership_revision: 1,
        reason: "operator stop"
      }
    }

    state = :sys.get_state(pid)

    data =
      state.managed.data
      |> put_in([:assignments, "item-1", :phase], :active)
      |> put_in([:assignments, "item-1", :board_state], :active)
      |> put_in([:assignments, "item-1", :revision], 2)
      |> put_in([:effect_intents, request.request_id], %{
        request_id: request.request_id,
        request: request,
        binding: state.managed.data.projects["PVT_test"],
        principal_context: SymphonyElixir.ManagedOrchestratorTestControl.principal(),
        assignment_id: "item-1",
        target: :waiting,
        context: Map.put(SymphonyElixir.ManagedOrchestratorTestControl.principal(), :stop_reconciled, true),
        status: :pending
      })

    :sys.replace_state(pid, fn current -> %{current | managed: %{current.managed | data: data}} end)
    assert {:error, {:stale_revision, _details}} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, request)
    refute_receive {:requirements_transition, _assignment}, 100
    refute_receive {:requirements_transition_rejected, _assignment}, 100
    state = :sys.get_state(pid)
    assert state.managed.data.effect_intents[request.request_id].status == :pending
  end

  test "managed dispatch failures retry twice then block" do
    {pid, _path} = managed_server()

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    attempt = fn generation ->
      %{assignment_id: "item-1", revision: 1, generation: generation, attempt_id: "attempt-#{generation}"}
    end

    failed_once =
      Orchestrator.mark_managed_dispatch_failed_for_test(
        :sys.get_state(pid),
        "item-1",
        attempt.(1),
        :spawn_failed
      )

    assignment = failed_once.managed.data.assignments["item-1"]
    assert assignment.phase == :ready
    assert assignment.board_state == :ready
    assert assignment.retry_count == 1
    assert assignment.pending_effect.status == :retry_pending
    assert assignment.pending_effect.reason == ":spawn_failed"

    failed_twice =
      Orchestrator.mark_managed_dispatch_failed_for_test(
        failed_once,
        "item-1",
        attempt.(2),
        :spawn_failed
      )

    assignment = failed_twice.managed.data.assignments["item-1"]
    assert assignment.phase == :ready
    assert assignment.board_state == :ready
    assert assignment.retry_count == 2
    assert assignment.pending_effect.status == :retry_pending

    failed_three_times =
      Orchestrator.mark_managed_dispatch_failed_for_test(
        failed_twice,
        "item-1",
        attempt.(3),
        :spawn_failed
      )

    assignment = failed_three_times.managed.data.assignments["item-1"]
    assert assignment.phase == :waiting
    assert assignment.board_state == :waiting
    assert assignment.retry_count == 3
    assert assignment.pending_effect.status == :failed
    assert assignment.blocked_reason == ":spawn_failed"

    dispatch_failures =
      failed_three_times.managed.data.events
      |> Enum.filter(&(&1.operation == :dispatch_failed))
      |> Enum.reverse()

    assert Enum.map(dispatch_failures, & &1.retry_count) == [1, 2, 3]
    assert Enum.map(dispatch_failures, & &1.phase) == [:ready, :ready, :waiting]
  end

  test "managed retry eligibility uses the revised absolute lifetime turn limit above twenty" do
    {pid, _path} = managed_server()

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind-extended-retry", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll-extended-retry", operation: :enroll, args: enrollment_args()})

    state = :sys.get_state(pid)

    assignment =
      Map.merge(state.managed.data.assignments["item-1"], %{
        turn_limit: 30,
        turn_limit_reason: "Complete recovery after the initial lifetime allocation",
        turns_reserved: 20,
        retry_count: 0
      })

    state = put_in(state.managed.data.assignments["item-1"], assignment)

    failed =
      Orchestrator.mark_managed_dispatch_failed_for_test(
        state,
        "item-1",
        %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-extended"},
        :spawn_failed
      )

    assignment = failed.managed.data.assignments["item-1"]
    assert assignment.phase == :ready
    assert assignment.retry_count == 1
    assert assignment.pending_effect.status == :retry_pending
  end

  test "dispatch failure preserves an uncertain provider transition" do
    {pid, _path} = managed_server()

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    state = :sys.get_state(pid)

    provider_effect = %{
      kind: :provider_transition,
      target: :active,
      status: :failed,
      error: :managed_provider_effect_failed
    }

    intent = %{
      request_id: "auto-active",
      request: nil,
      binding: state.managed.data.projects["PVT_test"],
      assignment_id: "item-1",
      target: :active,
      auto: true,
      status: :pending,
      last_error: :managed_provider_effect_failed
    }

    data =
      state.managed.data
      |> put_in([:assignments, "item-1", :pending_effect], provider_effect)
      |> put_in([:effect_intents, "auto-active"], intent)

    state = %{state | managed: %{state.managed | data: data}}

    failed =
      Orchestrator.mark_managed_dispatch_failed_for_test(
        state,
        "item-1",
        %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-provider"},
        {:managed_provider_effect_failed, :transport_unknown}
      )

    assignment = failed.managed.data.assignments["item-1"]
    assert assignment.phase == :ready
    assert assignment.retry_count == 1
    assert assignment.pending_effect == provider_effect
    assert failed.managed.data.effect_intents["auto-active"] == intent
  end

  test "startup transition recovery loads an unloaded provider beam" do
    module = Module.concat(__MODULE__, :"ColdEffects#{System.unique_integer([:positive])}")
    module_name = inspect(module)
    root = Path.join(System.tmp_dir!(), "managed-cold-effects-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    source = """
    defmodule #{module_name} do
      def transition(assignment, target, _context) do
        send(self(), {:cold_provider_transition, assignment.assignment_id, target})
        {:ok, %{provider_state: target, reconciled: true, external_effects: %{status: :ok}}}
      end
    end
    """

    [{^module, beam}] = Code.compile_string(source, Path.join(root, "cold_effects.ex"))
    beam_path = Path.join(root, Atom.to_string(module) <> ".beam")
    File.write!(beam_path, beam)
    code_path = String.to_charlist(root)
    true = :code.add_patha(code_path)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      :code.del_path(code_path)
      File.rm_rf(root)
    end)

    assert {:file, _path} = :code.is_loaded(module)
    :code.purge(module)
    :code.delete(module)
    assert false == :code.is_loaded(module)

    {pid, _path} = managed_server()
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    state = :sys.get_state(pid)

    data =
      state.managed.data
      |> put_in([:assignments, "item-1", :phase], :ready)
      |> put_in([:assignments, "item-1", :board_state], :ready)
      |> put_in([:effect_intents, "cold-active"], %{
        request_id: "cold-active",
        request: nil,
        binding: state.managed.data.projects["PVT_test"],
        assignment_id: "item-1",
        target: :active,
        status: :pending
      })

    recovered =
      Orchestrator.recover_managed_transitions_for_test(%{
        state
        | managed: %{state.managed | data: data, effects: module}
      })

    assert_receive {:cold_provider_transition, "item-1", :active}
    assert {:file, _path} = :code.is_loaded(module)
    assert recovered.managed.data.assignments["item-1"].pending_effect.status == :reconciled
    assert recovered.managed.data.effect_intents["cold-active"].status == :effect_reconciled
  end
end

defmodule SymphonyElixir.ManagedOrchestratorSourceReconciliationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.{Control, Journal, Rules}
  alias SymphonyElixir.Tracker.Issue

  defp body_fingerprint(body) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end

  defp binding_args do
    %{
      expected_revision: 0,
      project: %{
        project_id: "PVT_test",
        project_number: 4,
        status_field_id: "PVTSSF_test",
        status_options: %{
          "READY" => "ready",
          "ACTIVE" => "active",
          "REVIEW" => "review",
          "ACCEPTED" => "accepted",
          "WAITING" => "waiting",
          "CANCELLED" => "cancelled"
        },
        repositories: ["acme/example"]
      }
    }
  end

  test "source polling persists READY to ACTIVE and metadata refreshes without stopping the worker" do
    workflow_path = Workflow.workflow_file_path()
    write_workflow_file!(workflow_path, tracker_kind: "github_projects")

    workflow_path
    |> File.read!()
    |> String.replace(
      "  kind: \"github_projects\"\n",
      "  kind: \"github_projects\"\n  provider: {owner_type: \"org\", owner: \"fixture\", project_number: 1, token: \"token\"}\n"
    )
    |> then(&File.write!(workflow_path, &1))

    assert :ok = WorkflowStore.force_reload()
    assert Config.settings!().tracker.kind == "github_projects"

    name = Module.concat(__MODULE__, :"server_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "managed-source-#{System.unique_integer([:positive])}.log")
    {:ok, pid} = Orchestrator.start_link(name: name, managed_effects: SymphonyElixir.ManagedReviewEffectsStub)
    {:ok, journal, %{}} = Journal.open(path, name: String.to_atom("managed_source_#{System.unique_integer([:positive])}"))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{journal: journal, data: Rules.new(), effects: SymphonyElixir.ManagedReviewEffectsStub}, poll_check_in_progress: true}
    end)

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})

    body = "requirements"

    enrollment = %{
      expected_revision: 1,
      assignment_id: "item-1",
      repository: "acme/example",
      issue_number: 5,
      base_commit: "base",
      board_state: "READY",
      resources: [%{kind: :repository, authority: "github.com", identity: "acme/example", access: :write}],
      dependencies: [],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"},
      requirements_fingerprint: body_fingerprint(body),
      requirements_revision: 1
    }

    issue = %Issue{
      id: "item-1",
      identifier: "acme/example#5",
      state: "ACTIVE",
      description: body,
      dispatchable: true,
      native_ref: %{
        "project_item_id" => "item-1",
        "issue_id" => "I_1",
        "issue_number" => 5,
        "content_type" => "Issue",
        "issue_state" => "OPEN",
        "repository" => %{"id" => "R_1", "name_with_owner" => "acme/example"}
      }
    }

    ready_issue = %{issue | state: "READY"}

    :sys.replace_state(pid, fn state ->
      %{state | managed: Map.put(state.managed, :source_fetcher, fn _ids -> {:ok, [ready_issue]} end)}
    end)

    assert {:ok, _} = SymphonyElixir.ManagedOrchestratorTestControl.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment})

    :sys.replace_state(pid, fn state ->
      data =
        put_in(
          state.managed.data,
          [:assignments, "item-1"],
          Map.merge(state.managed.data.assignments["item-1"], %{
            phase: :active,
            board_state: :active,
            generation: 1,
            attempt_id: "attempt-1",
            turn_limit: 2,
            turns_reserved: 0,
            source_authoritative: true,
            source_state: "READY"
          })
        )

      fake_pid = spawn(fn -> Process.sleep(:infinity) end)

      running = %{
        pid: fake_pid,
        ref: make_ref(),
        managed_attempt: %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-1"}
      }

      %{
        state
        | managed: %{
            journal: journal,
            data: data,
            effects: SymphonyElixir.ManagedReviewEffectsStub,
            source_fetcher: fn _ids -> {:ok, [issue]} end
          },
          running: %{"item-1" => running},
          poll_check_in_progress: true
      }
    end)

    attempt = %{assignment_id: "item-1", revision: 1, generation: 1, attempt_id: "attempt-1"}
    assert :allow = GenServer.call(pid, {:managed_before_turn, %{attempt: attempt}})
    assert Process.alive?(:sys.get_state(pid).running["item-1"].pid)

    assert {:ok, snapshot} = Control.state(pid)
    assignment = snapshot.assignments["item-1"]
    assert assignment.native_issue_id == "I_1"
    assert assignment.native_repository_id == "R_1"
    assert assignment.project_item_id == "item-1"
    assert assignment.source_state == "ACTIVE"
    assert assignment.revision == 1
    assert snapshot.revision == 2

    metadata_refresh = %{issue | state: "active"}

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{state.managed | source_fetcher: fn _ids -> {:ok, [metadata_refresh]} end}}
    end)

    assert :allow = GenServer.call(pid, {:managed_before_turn, %{attempt: attempt}})
    assert Process.alive?(:sys.get_state(pid).running["item-1"].pid)

    assert {:ok, refreshed_snapshot} = Control.state(pid)
    assert refreshed_snapshot.assignments["item-1"].source_state == "active"
    assert refreshed_snapshot.assignments["item-1"].phase == :active
    assert refreshed_snapshot.assignments["item-1"].revision == 1
    assert refreshed_snapshot.revision == 2

    changed_issue = %{issue | description: "changed"}

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{state.managed | source_fetcher: fn _ids -> {:ok, [changed_issue]} end}}
    end)

    assert {:stop, :managed_source_material_changed} =
             GenServer.call(pid, {:managed_before_turn, %{attempt: attempt}})

    Process.exit(:sys.get_state(pid).running["item-1"].pid, :kill)
  end
end

defmodule SymphonyElixir.ManagedOrchestratorUsageRecoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.{Control, Journal, Rules}

  test "startup usage recovery clears persisted inflight tokens before dispatch" do
    name = Module.concat(__MODULE__, :"server_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "managed-usage-recovery-#{System.unique_integer([:positive])}.log")
    {:ok, pid} = Orchestrator.start_link(name: name, managed_effects: SymphonyElixir.ManagedReviewEffectsStub)
    {:ok, journal, %{}} = Journal.open(path, name: String.to_atom("managed_usage_#{System.unique_integer([:positive])}"))

    :sys.replace_state(pid, fn state ->
      data = put_in(Rules.new(), [:usage, :inflight_tokens], 42)

      %{
        state
        | managed: %{journal: journal, data: data, effects: SymphonyElixir.ManagedReviewEffectsStub},
          poll_check_in_progress: true
      }
    end)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    state = :sys.get_state(pid)
    recovered = Orchestrator.recover_managed_usage_inflight_for_test(state)
    :sys.replace_state(pid, fn _ -> recovered end)

    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.usage.inflight_tokens == 0

    assert {:ok, events} = Control.events(pid, 0, 100)
    assert Enum.any?(events, &(&1.operation == :startup_usage_recovery))
  end
end

defmodule SymphonyElixir.ManagedOperatorTakeoverRecoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.{Control, Journal, Principal, Rules}

  defp binding_args do
    %{
      expected_revision: 0,
      project: %{
        project_id: "PVT_takeover",
        project_number: 4,
        status_field_id: "PVTSSF_takeover",
        status_options: %{
          "READY" => "ready",
          "ACTIVE" => "active",
          "REVIEW" => "review",
          "ACCEPTED" => "accepted",
          "WAITING" => "waiting",
          "CANCELLED" => "cancelled"
        },
        repositories: ["acme/example"]
      }
    }
  end

  defp enrollment_args do
    %{
      expected_revision: 1,
      assignment_id: "stale-waiting",
      project_id: "PVT_takeover",
      repository: "acme/example",
      issue_number: 5,
      base_commit: "base",
      board_state: "READY",
      resources: [%{kind: :repository, authority: "github.com", identity: "acme/example", access: :write}],
      dependencies: [],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"}
    }
  end

  defp pm(principal_id), do: %{principal_id: principal_id, role: :pm, project_scope: :all}

  defp managed_server do
    name = Module.concat(__MODULE__, :"server_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "managed-takeover-#{System.unique_integer([:positive])}.log")
    {:ok, pid} = Orchestrator.start_link(name: name, managed_effects: SymphonyElixir.ManagedReviewEffectsStub)
    {:ok, journal, %{}} = Journal.open(path, name: String.to_atom("managed_takeover_#{System.unique_integer([:positive])}"))

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{journal: journal, data: Rules.new(), effects: SymphonyElixir.ManagedReviewEffectsStub}, poll_check_in_progress: true}
    end)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1)
    end)

    pid
  end

  defp enroll_assignment(pid) do
    assert {:ok, _} =
             Control.submit_authorized(
               pid,
               %{request_id: "bind-takeover", operation: :bind_project, args: binding_args()},
               Principal.operator()
             )

    assert {:ok, _} =
             Control.submit_authorized(
               pid,
               %{request_id: "enroll-takeover", operation: :enroll, args: enrollment_args()},
               pm("source-pm")
             )

    assert {:ok, _} =
             Control.submit_authorized(
               pid,
               %{request_id: "register-target", operation: :register_pm, args: %{display_name: "Target PM"}},
               pm("target-pm")
             )
  end

  defp takeover_envelope(revision \\ 1) do
    %{
      request_id: "takeover-stale-waiting",
      operation: :operator_takeover,
      args: %{
        project_id: "PVT_takeover",
        destination_pm_id: "target-pm",
        reason: "recover stale worker",
        assignments: [%{assignment_id: "stale-waiting", expected_revision: revision, expected_ownership_revision: 1}]
      }
    }
  end

  test "operator takeover proves and clears a stale WAITING stop before transfer" do
    parent = self()
    pid = managed_server()
    enroll_assignment(pid)

    metadata = %{containment: :test_recorded_process, process_id: "stale-waiting"}

    stopper = fn ^metadata ->
      send(parent, {:stop_recorded_process, metadata})
      :ok
    end

    :sys.replace_state(pid, fn state ->
      data =
        update_in(state.managed.data, [:assignments, "stale-waiting"], fn assignment ->
          Map.merge(assignment, %{phase: :waiting, board_state: :waiting, stop_pending: true, metadata: metadata})
        end)

      managed = Map.put(state.managed, :data, data) |> Map.put(:process_stopper, stopper)
      %{state | managed: managed}
    end)

    assert {:ok, response} = Control.submit(pid, takeover_envelope())
    assert response.operation == :operator_takeover
    assert_received {:stop_recorded_process, ^metadata}

    assert {:ok, snapshot} = Control.state(pid)
    assignment = snapshot.assignments["stale-waiting"]
    assert assignment.phase == :waiting
    assert assignment.stop_pending == false
    assert assignment.stop_reconciled == true
    assert assignment.ownership.pm_id == "target-pm"
    assert snapshot.external_reconciliations["stale-waiting"].process_stopped == true
  end

  test "operator takeover retains stale stop state when recorded process proof is unknown" do
    pid = managed_server()
    enroll_assignment(pid)
    stopper = fn _metadata -> {:error, :process_identity_unknown} end

    :sys.replace_state(pid, fn state ->
      data =
        update_in(state.managed.data, [:assignments, "stale-waiting"], fn assignment ->
          Map.merge(assignment, %{phase: :waiting, board_state: :waiting, stop_pending: true, metadata: %{containment: :unknown}})
        end)

      managed = Map.put(state.managed, :data, data) |> Map.put(:process_stopper, stopper)
      %{state | managed: managed}
    end)

    assert {:error, :managed_process_stop_unconfirmed, %{reason: {"stale-waiting", :process_identity_unknown}}} =
             Control.submit(pid, takeover_envelope())

    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.assignments["stale-waiting"].stop_pending == true
    assert snapshot.assignments["stale-waiting"].ownership.pm_id == "source-pm"

    refute Map.has_key?(snapshot, :external_reconciliations) and
             Map.has_key?(snapshot.external_reconciliations, "stale-waiting")
  end

  test "invalid takeover fences fail before a stale process stop is attempted" do
    parent = self()
    pid = managed_server()
    enroll_assignment(pid)

    stopper = fn metadata ->
      send(parent, {:unexpected_stop, metadata})
      :ok
    end

    :sys.replace_state(pid, fn state ->
      data =
        update_in(state.managed.data, [:assignments, "stale-waiting"], fn assignment ->
          Map.merge(assignment, %{phase: :waiting, board_state: :waiting, stop_pending: true, metadata: %{containment: :test_recorded_process}})
        end)

      managed = Map.put(state.managed, :data, data) |> Map.put(:process_stopper, stopper)
      %{state | managed: managed}
    end)

    assert {:error, :stale_revision, %{expected: 99, actual: 1}} = Control.submit(pid, takeover_envelope(99))
    refute_received {:unexpected_stop, _}
  end
end
