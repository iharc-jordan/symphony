defmodule SymphonyElixir.ManagedOwnershipHttpTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  import Plug.Conn
  alias SymphonyElixir.Managed.{Control, Journal, Rules}
  @endpoint SymphonyElixirWeb.Endpoint
  @pm_a "00000000-0000-4000-8000-000000000001"
  @pm_b "00000000-0000-4000-8000-000000000002"
  @secret "managed-http-fixture-secret"

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    token_path = Path.join(root, "control.token")
    File.write!(token_path, @secret)
    workflow = File.read!(Workflow.workflow_file_path())
    File.write!(Workflow.workflow_file_path(), String.replace(workflow, "---\n", "---\nmanaged:\n  enabled: false\n  control_token_file: #{token_path}\n", global: false))
    :ok = WorkflowStore.force_reload()

    name = Module.concat(__MODULE__, :"server_#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)
    {:ok, journal, %{}} = Journal.open(Path.join(root, "managed.sqlite3"))

    :sys.replace_state(pid, fn state ->
      %{state | managed: %{journal: journal, data: Rules.new(paused: true), effects: __MODULE__}, poll_check_in_progress: true}
    end)

    previous = Application.get_env(:symphony_elixir, @endpoint, [])
    Application.put_env(:symphony_elixir, @endpoint, Keyword.merge(previous, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: name))
    start_supervised!({@endpoint, []})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Journal.close(journal)
      Application.put_env(:symphony_elixir, @endpoint, previous)
    end)

    %{pid: pid}
  end

  test "HTTP identity fences one active assignment across PM handoff", %{pid: pid} do
    bind = %{request_id: "bind", operation: "bind_project", args: %{expected_revision: 0, project: binding("PVT_one", "acme/one")}}
    assert %{"operation" => "bind_project"} = json_response(request(@secret, bind), 200)
    assert request(credential(@pm_a), %{bind | request_id: "pm-bind"}).status == 409

    enroll = %{
      request_id: "enroll",
      operation: "enroll",
      args: %{
        expected_revision: 1,
        project_id: "PVT_one",
        assignment_id: "item-one",
        repository: "acme/one",
        issue_number: 1,
        base_commit: "base",
        board_state: "READY",
        dependencies: [],
        resources: [%{kind: "repository", authority: "github.com", identity: "acme/one", access: "write"}],
        route: %{model: "gpt-5.6-luna", effort: "xhigh"}
      }
    }

    assert request(credential(@pm_a), enroll).status == 200
    assert request(credential(@pm_b), %{request_id: "register-b", operation: "register_pm", args: %{display_name: "PM B"}}).status == 200

    :sys.replace_state(pid, fn state ->
      data = update_in(state.managed.data, [:assignments, "item-one"], &Map.merge(&1, %{phase: :active, thread_id: "worker-stays", attempt_id: "attempt-stays", worker_active: true}))
      %{state | managed: %{state.managed | data: data}}
    end)

    fence = %{assignment_id: "item-one", expected_revision: 1, expected_ownership_revision: 1}

    handoff = %{
      request_id: "handoff",
      operation: "handoff",
      args: %{project_id: "PVT_one", assignments: [fence], destination_pm_id: @pm_b, reason: "Fresh PM context"}
    }

    assert %{"operation" => "handoff"} = json_response(request(credential(@pm_a), handoff), 200)
    {:ok, state} = Control.state(pid)
    assignment = state.assignments["item-one"]
    assert assignment.revision == 1
    assert assignment.ownership.pm_id == @pm_b
    assert assignment.ownership.ownership_revision == 2
    assert assignment.thread_id == "worker-stays"
    assert assignment.attempt_id == "attempt-stays"

    pause = %{
      request_id: "pause",
      operation: "pause",
      args: %{scope: "assignments", project_id: "PVT_one", assignments: [%{fence | expected_ownership_revision: 2}]}
    }

    old_owner = request(credential(@pm_a), pause) |> json_response(409)
    assert old_owner["error"]["code"] == "ownership_conflict"
    assert old_owner["error"]["details"]["responsible_pm_id"] == @pm_b
    assert request(credential(@pm_b), pause).status == 200
    {:ok, paused} = Control.state(pid)
    assert paused.assignments["item-one"].revision == 1
    assert paused.assignments["item-one"].dispatch_paused == true
    assert paused.assignments["item-one"].worker_active == true

    service = %{request_id: "service-pause", operation: "pause", args: %{scope: "service", expected_revision: paused.revision}}
    assert request(credential(@pm_b), service).status == 409
    refute inspect(paused) =~ @secret
    refute inspect(paused) =~ "pm-v1."
  end

  test "one PM owns separate Projects and duplicate issue cards are rejected globally", %{pid: pid} do
    first_binding = binding("PVT_one", "acme/one")
    second_binding = %{binding("PVT_two", "acme/two") | repositories: ["acme/one", "acme/two"]}

    for {project, revision} <- [{first_binding, 0}, {second_binding, 1}] do
      bind = %{request_id: "bind-#{revision}", operation: "bind_project", args: %{expected_revision: revision, project: project}}
      assert %{"operation" => "bind_project"} = json_response(request(@secret, bind), 200)
    end

    for {project, id, repository, issue_id, repository_id, revision} <- [
          {"PVT_one", "item-one", "acme/one", "I_one", "R_one", 2},
          {"PVT_two", "item-two", "acme/two", "I_two", "R_two", 3}
        ] do
      args = enrollment(project, id, repository, issue_id, repository_id, revision)
      body = %{request_id: "enroll-#{id}", operation: "enroll", args: args}
      assert %{"operation" => "enroll"} = json_response(request(credential(@pm_a), body), 200)
    end

    {:ok, state} = Control.state(pid)
    assert map_size(state.projects) == 2
    assert state.assignments["item-one"].ownership.pm_id == @pm_a
    assert state.assignments["item-two"].ownership.pm_id == @pm_a
    assert state.assignments["item-two"].project_id == "PVT_two"

    args = enrollment("PVT_two", "second-card", "acme/one", "I_one", "R_one", 4)
    duplicate = %{request_id: "duplicate-card", operation: "enroll", args: args}
    error = json_response(request(credential(@pm_b), duplicate), 409)["error"]
    assert error["code"] == "duplicate_underlying_identity"
    assert error["details"]["assignment_id"] == "item-one"
    {:ok, unchanged} = Control.state(pid)
    assert unchanged.revision == 4
    assert map_size(unchanged.assignments) == 2
  end

  test "HTTP rejects tampered credentials before mutating the journal", %{pid: pid} do
    body = %{request_id: "register", operation: "register_pm", args: %{display_name: "PM"}}
    forged = String.replace(credential(@pm_a), @pm_a, @pm_b)
    assert request(forged, body).status == 401
    {:ok, state} = Control.state(pid)
    assert state.revision == 0
    assert state.assignments == %{}
  end

  test "managed state GET supports compact summary, assignment detail, and clear invalid query errors", %{pid: pid} do
    assignment = %{
      assignment_id: "item-one",
      project_id: "PVT_one",
      repository: "acme/one",
      issue_number: 1,
      phase: :review,
      board_state: :review,
      ownership: %{status: :owned, pm_id: @pm_a, ownership_revision: 1},
      reports: %{"r-1" => %{report_id: "r-1", evidence: ["proof"]}},
      last_report: %{report_id: "r-1", kind: "result", summary: "done", evidence: ["proof"]}
    }

    :sys.replace_state(pid, fn state ->
      data =
        Rules.new(
          control_revision: 3,
          event_cursor: 4,
          projects: %{"PVT_one" => %{project_id: "PVT_one", revision: 1}},
          assignments: %{"item-one" => assignment},
          paused: false
        )

      %{state | managed: %{state.managed | data: data}}
    end)

    summary = get_request(@secret, "/api/v1/managed/state") |> json_response(200)
    assert summary["view"] == "summary"
    assert summary["control_revision"] == 3
    assert summary["assignments"]["item-one"]["phase"] == "review"
    refute Map.has_key?(summary, "events")

    detail =
      get_request(@secret, "/api/v1/managed/state?view=detail&assignment_id=item-one")
      |> json_response(200)

    assert detail["view"] == "detail"
    assert detail["assignment"]["reports"]["r-1"]["evidence"] == ["proof"]

    invalid = get_request(@secret, "/api/v1/managed/state?view=compact") |> json_response(400)
    assert invalid["error"]["code"] == "invalid_request"
    assert invalid["error"]["details"]["field"] == "view"
  end

  defp get_request(token, path) do
    build_conn(:get, path)
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(path)
  end

  defp request(token, body) do
    build_conn(:post, "/api/v1/managed/control")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/api/v1/managed/control", body)
  end

  defp binding(id, repository) do
    %{
      project_id: id,
      project_number: 1,
      status_field_id: "status-#{id}",
      repositories: [repository],
      requirements_path: Path.expand("../fixtures/REQUIREMENTS.md", __DIR__),
      status_options: Map.new(~w(READY ACTIVE REVIEW ACCEPTED WAITING CANCELLED), &{&1, String.downcase(&1)})
    }
  end

  defp enrollment(project, id, repository, issue_id, repository_id, revision) do
    %{
      expected_revision: revision,
      project_id: project,
      assignment_id: id,
      repository: repository,
      issue_number: 1,
      native_issue_id: issue_id,
      native_repository_id: repository_id,
      base_commit: "base",
      board_state: "READY",
      dependencies: [],
      resources: [%{kind: "repository", authority: "github.com", identity: repository, access: "read"}],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"}
    }
  end

  defp credential(id) do
    signature = :crypto.mac(:hmac, :sha256, @secret, "codex-orchestration-pm-v1:" <> id)
    "pm-v1.#{id}.#{Base.encode16(signature, case: :lower)}"
  end
end
