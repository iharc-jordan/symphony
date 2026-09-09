defmodule SymphonyElixir.ManagedReviewEffectsStub do
  def review(_assignment, _args, _context) do
    {:ok, %{provider_state: :review, provider_final_state: :accepted, issue_final_state: :closed, reconciled: true, external_effects: %{status: :ok, issue_close: :ok}}}
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
               args: %{assignment_id: "item-1", expected_revision: 1, disposition: "accepted", evidence: ["test"], provider_state: "ACTIVE", reconciled: false}
             })

    assert response.phase == :accepted
  end
end
