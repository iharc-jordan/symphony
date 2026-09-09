defmodule SymphonyElixir.ManagedReviewEffectsStub do
  def review(_assignment, _args, _context) do
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

defmodule SymphonyElixir.ManagedOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.{Control, Journal, Rules}

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
      resources: ["repo:acme/example"],
      dependencies: [],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"}
    }
  end

  defp managed_server do
    name = Module.concat(__MODULE__, :"server_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "managed-orchestrator-#{System.unique_integer([:positive])}.log")
    {:ok, pid} = Orchestrator.start_link(name: name, managed_effects: SymphonyElixir.ManagedReviewEffectsStub)
    {:ok, journal, %{}} = Journal.open(path, name: String.to_atom("managed_test_#{System.unique_integer([:positive])}"))

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{journal: journal, data: Rules.new(), effects: SymphonyElixir.ManagedReviewEffectsStub}, poll_check_in_progress: true}
    end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm(path)
    end)

    {pid, path}
  end

  test "managed control is serialized, durable, and exposes revision and cursor" do
    {pid, _path} = managed_server()

    assert {:ok, %{operation: :bind_project, revision: 1}} =
             Control.submit(pid, %{request_id: "bind", operation: "bind_project", args: binding_args()})

    assert {:ok, %{operation: :enroll, assignment_id: "item-1", revision: 1}} =
             Control.submit(pid, %{request_id: "enroll", operation: "enroll", args: enrollment_args()})

    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.revision == 2
    assert snapshot.cursor == 2
    assert snapshot.assignments["item-1"].repository == "acme/example"

    assert {:ok, duplicate} =
             Control.submit(pid, %{request_id: "enroll", operation: "enroll", args: enrollment_args()})

    assert duplicate.duplicate == true
  end

  test "accepted review journals intent and service reconciliation before commit" do
    {pid, _path} = managed_server()
    assert {:ok, _} = Control.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = Control.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

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
             Control.submit(pid, %{request_id: "review-1", operation: :review, args: args})

    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.assignments["item-1"].phase == :accepted

    assert {:ok, events} = Control.events(pid, 0, 100)
    operations = Enum.map(events, & &1.operation)
    assert :review_intent in operations
    assert :reconcile in operations
    assert :review in operations
    assert :review_committed in operations
  end

  test "managed callbacks fence stale attempts, reserve turns, and retain review reports" do
    {pid, _path} = managed_server()
    assert {:ok, _} = Control.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = Control.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

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

  test "service reconciliation supplies review facts while caller fields are ignored" do
    {pid, _path} = managed_server()
    assert {:ok, _} = Control.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = Control.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

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
             Control.submit(pid, %{
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
      resources: ["repo:acme/example"],
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
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm(path)
    end)

    assert {:ok, _} = Control.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = Control.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

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
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm(path)
    end)

    assert {:ok, _} = Control.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = Control.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

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
             Control.submit(pid, %{
               request_id: "interrupt-1",
               operation: :interrupt,
               args: %{assignment_id: "item-1", expected_revision: 1, reason: "operator stop"}
             })

    assert pending.pending == true
    assert pending.stop_pending == true

    send(pid, {:DOWN, ref, :process, fake_pid, {:managed_agent_guard_stop, :managed_stop_pending}})
    _ = Control.state(pid)

    assert {:ok, snapshot} = Control.state(pid)
    assert snapshot.assignments["item-1"].phase == :waiting
    assert snapshot.assignments["item-1"].board_state == :waiting

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
      resources: ["repo:acme/example"],
      dependencies: [],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"}
    }
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
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm(path)
    end)

    assert {:ok, _} = Control.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})
    assert {:ok, _} = Control.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment_args()})

    state = :sys.get_state(pid)

    data =
      state.managed.data
      |> put_in([:assignments, "item-1", :phase], :ready)
      |> put_in([:assignments, "item-1", :board_state], :ready)
      |> put_in([:effect_intents, "auto-ready"], %{
        request_id: "auto-ready",
        request: nil,
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
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm(path)
    end)

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{journal: journal, data: Rules.new(), effects: SymphonyElixir.ManagedReviewEffectsStub}, poll_check_in_progress: true}
    end)

    assert {:ok, _} = Control.submit(pid, %{request_id: "bind", operation: :bind_project, args: binding_args()})

    body = "requirements"

    enrollment = %{
      expected_revision: 1,
      assignment_id: "item-1",
      repository: "acme/example",
      issue_number: 5,
      base_commit: "base",
      board_state: "READY",
      resources: ["repo:acme/example"],
      dependencies: [],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"},
      requirements_fingerprint: body_fingerprint(body),
      requirements_revision: 1
    }

    assert {:ok, _} = Control.submit(pid, %{request_id: "enroll", operation: :enroll, args: enrollment})

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
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm(path)
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
