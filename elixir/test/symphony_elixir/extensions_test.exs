defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(issue_ids) do
      send(self(), {:fetch_issues_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:managed_state, _from, state) do
      {:reply, Keyword.get(state, :managed_state, {:error, :managed_mode_disabled}), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Second prompt",
      poll_interval_ms: 45_000
    )

    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    good_settings = Config.settings!()
    assert good_settings.polling.interval_ms == 45_000

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    File.write!(
      Workflow.workflow_file_path(),
      "---\npolling:\n  interval_ms: nope\n---\nTyped-invalid prompt\n"
    )

    assert {:error, {:invalid_workflow_config, message}} = WorkflowStore.force_reload()
    assert message =~ "polling.interval_ms"
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()
    assert Config.settings!().polling.interval_ms == good_settings.polling.interval_ms
    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil,
      prompt: "Semantic-invalid prompt"
    )

    assert {:error, :missing_linear_project_slug} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()
    assert Config.settings!().polling.interval_ms == good_settings.polling.interval_ms
    assert {:error, :missing_linear_project_slug} = Config.validate!()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert {:ok, settings} = WorkflowStore.settings()
    assert settings.polling.interval_ms == 30_000
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.settings()

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    assert :ok = GenServer.stop(manual_pid)

    Workflow.set_workflow_file_path(existing_path)

    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    assert :ok = WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_ids(["issue-1"])

    binding = SymphonyElixir.Tracker.bind_agent_tools()
    assert binding.adapter == Memory
    assert binding.tool_specs == []
    assert binding.secret_environment_names == []

    assert SymphonyElixir.Tracker.execute_bound_agent_tool(binding, "not_a_memory_tool", %{})[
             "success"
           ] == false

    assert {:error, {:unsupported_tracker_kind, "future-tracker"}} =
             SymphonyElixir.Tracker.adapter_for_kind("future-tracker")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
    assert SymphonyElixir.Tracker.bind_agent_tools().secret_environment_names == ["LINEAR_API_KEY"]
  end

  test "linear adapter delegates reads and advertises its native agent tool" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issues_by_ids(["issue-1"])
    assert_receive {:fetch_issues_by_ids_called, ["issue-1"]}

    assert [%{"name" => "linear_graphql"}] = Adapter.agent_tool_specs()
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1, "blocked" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "issue_url" => "https://example.org/issues/MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "issue_url" => "https://example.org/issues/MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "issue_url" => "https://example.org/issues/MT-BLOCKED",
                 "state" => "In Progress",
                 "error" => "codex turn requires operator input",
                 "worker_host" => "dm-dev2",
                 "workspace_path" => "/workspaces/MT-BLOCKED",
                 "session_id" => "thread-blocked",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "last_event" => "turn_input_required",
                 "last_message" => "turn blocked: waiting for user input",
                 "last_event_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("last_event_at")
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "blocked" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "last_error" => "codex turn requires operator input",
             "blocked" => %{
               "session_id" => "thread-blocked",
               "state" => "In Progress",
               "error" => "codex turn requires operator input"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ ~r|/dashboard\.css\?v=[0-9a-f]{12}|

    assert html =~
             ~r|<link rel="icon" type="image/png" sizes="128x128" href="/favicon\.png\?v=[0-9a-f]{12}">|

    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ "text-decoration-thickness: 1px"

    favicon_conn = get(build_conn(), "/favicon.png")
    assert response(favicon_conn, 200) == File.read!("priv/static/favicon.png")
    assert Plug.Conn.get_resp_header(favicon_conn, "content-type") == ["image/png; charset=utf-8"]

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Live work"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "MT-BLOCKED"
    assert html =~ ~s(href="https://example.org/issues/MT-HTTP")
    assert html =~ ~s(href="https://example.org/issues/MT-RETRY")
    assert html =~ ~s(href="https://example.org/issues/MT-BLOCKED")
    assert html =~ ~s(aria-label="Open MT-HTTP in the issue tracker")
    assert html =~ "rendered"
    assert html =~ "turn blocked: waiting for user input"
    assert html =~ "Runtime"
    assert html =~ "Live updates"
    assert html =~ "Disconnected"
    assert html =~ "Runtime details"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "javascript:alert('nope')",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)

    refute render(view) =~ "javascript:alert"
  end

  test "managed dashboard separates live work from history and preserves ownership selection" do
    orchestrator_name = Module.concat(__MODULE__, :ManagedDashboardOrchestrator)
    now = DateTime.utc_now()
    stale = DateTime.add(now, -600, :second)
    running_started_at = DateTime.add(now, -75, :second)

    managed_state = %{
      revision: 7,
      cursor: 12,
      paused: false,
      disabled: false,
      projects: %{
        "project-alpha" => %{project_id: "project-alpha", project_number: 4, repositories: ["org/repo-alpha"], revision: 2},
        "project-beta" => %{project_id: "project-beta", project_number: 8, repositories: ["org/repo-beta"], revision: 3}
      },
      principals: %{
        "pm-one" => %{display_name: "PM One", task_uuid: "task-pm-one"},
        "pm-two" => %{display_name: "PM Two", task_uuid: "task-pm-two"},
        "pm-history" => %{display_name: "History PM", task_uuid: "task-pm-history"}
      },
      assignments: %{
        "assign-active" => %{
          assignment_id: "assign-active",
          project_id: "project-alpha",
          repository: "org/repo-alpha",
          issue_number: 11,
          title: "Build alpha",
          phase: :active,
          status: "active",
          ownership: %{pm_id: "pm-one", status: :owned, ownership_revision: 4},
          worker_id: "worker-alpha",
          worker_active: true,
          worker_activity: "running tests",
          started_at: DateTime.add(now, -7_200, :second),
          usage: %{input_tokens: 901, output_tokens: 902, total_tokens: 1_803, seconds_running: 9_999},
          projection: %{status: :synced, revision: 2, updated_at: now, synced_at: now}
        },
        "assign-active-idle" => %{
          assignment_id: "assign-active-idle",
          project_id: "project-alpha",
          repository: "org/repo-alpha",
          issue_number: 12,
          title: "Phase active but idle",
          phase: :active,
          status: "active",
          ownership: %{pm_id: "pm-one", status: :owned, ownership_revision: 5},
          worker_active: false,
          usage: %{input_tokens: 21, output_tokens: 34, total_tokens: 55, seconds_running: 123},
          route: %{model: "gpt-5.6-luna", effort: "xhigh"}
        },
        "assign-queued" => %{
          assignment_id: "assign-queued",
          project_id: "project-beta",
          repository: "org/repo-beta",
          issue_number: 22,
          title: "Stale owner task",
          task_uuid: "task-beta",
          phase: :ready,
          status: "queued",
          ownership: %{pm_id: "pm-two", status: :needs_claim},
          projection: %{status: :pending, revision: 1, updated_at: stale, retry_at: now}
        },
        "assign-review" => %{
          assignment_id: "assign-review",
          project_id: "project-alpha",
          repository: "org/repo-alpha",
          issue_number: 33,
          title: "Review alpha",
          phase: :review,
          status: "review",
          ownership: %{pm_id: "pm-one", status: :owned},
          projection: %{status: :failed, revision: 5, updated_at: now, error: "provider projection failed"}
        },
        "assign-accepted" => %{
          assignment_id: "assign-accepted",
          project_id: "project-alpha",
          repository: "org/repo-alpha",
          issue_number: 44,
          title: "Finished history",
          phase: :accepted,
          status: "accepted",
          stop_pending: true,
          ownership: %{pm_id: "pm-history", status: :owned},
          worker_active: true,
          usage: %{input_tokens: 7, output_tokens: 8, total_tokens: 15, seconds_running: 64},
          started_at: DateTime.add(now, -3_600, :second)
        },
        "assign-cancelled" => %{
          assignment_id: "assign-cancelled",
          project_id: "project-beta",
          repository: "org/repo-beta",
          issue_number: 55,
          title: "Cancelled history",
          phase: :cancelled,
          status: "cancelled",
          stop_pending: true,
          ownership: %{status: :unassigned},
          worker_active: false
        }
      },
      events: [
        %{
          cursor: 12,
          at: now,
          operation: :handoff,
          status: :complete,
          source_pm_id: "pm-one",
          destination_pm_id: "pm-two",
          assignment_ids: ["assign-active"],
          reason: "capacity"
        },
        %{
          cursor: 11,
          at: now,
          operation: :operator_takeover,
          status: :complete,
          source_pm_id: "operator",
          destination_pm_id: "pm-one",
          assignment_id: "assign-review",
          reason: "review owner absent"
        }
      ]
    }

    running_entry =
      static_snapshot().running
      |> List.first()
      |> Map.merge(%{
        issue_id: "assign-active",
        identifier: "MT-ACTIVE",
        issue_url: "https://example.org/issues/MT-ACTIVE",
        started_at: running_started_at,
        codex_input_tokens: 4,
        codex_output_tokens: 8,
        codex_total_tokens: 12
      })

    dashboard_snapshot = put_in(static_snapshot(), [:running], [running_entry])

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: dashboard_snapshot,
        managed_state: {:ok, managed_state}
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert {:error, {:live_redirect, %{to: "/?pm=pm-one"}}} = live(build_conn(), "/")
    {:ok, view, html} = live(build_conn(), "/?pm=pm-one")
    assert html =~ "Live work"
    assert html =~ "PM One"
    assert html =~ "Build alpha"
    assert html =~ "Phase active but idle"
    assert html =~ "Needs a project manager"
    assert html =~ ~s(data-metric="runtime")
    assert html =~ ~s(data-metric="tokens")
    assert html =~ ~s(data-metric="tokens">Tokens <strong>12</strong>)
    assert html =~ ~s(data-metric="tokens">Tokens <strong>55</strong>)
    assert html =~ "Not recorded"
    refute html =~ "Finished history"
    refute html =~ "Cancelled history"
    refute html =~ "History PM"
    refute html =~ "Ownership transfer history"
    assert html =~ ~s(title="1 running workers")
    refute html =~ ~s(title="2 running workers")
    assert has_element?(view, ~s([data-assignment-id="assign-active"].worker-running))
    refute has_element?(view, ~s([data-assignment-id="assign-active-idle"].worker-running))
    assert html =~ "PM identity shows ownership, not whether its Codex task is currently running."

    view
    |> element("button.manager-option", "Needs a project manager")
    |> render_click()

    html = render(view)
    assert html =~ "Stale owner task"
    refute html =~ "PM Two"

    view
    |> element("button.manager-option", "PM One")
    |> render_click()

    assert has_element?(view, "#ownership-map")
    assert has_element?(view, ~s(button[phx-value-layout="map"]))
    assert has_element?(view, ~s(button[phx-value-layout="list"]))

    view
    |> element(~s(button[phx-value-layout="list"]))
    |> render_click()

    assert has_element?(view, "#live-list")
    refute has_element?(view, "#ownership-map")

    view
    |> element(~s(button[phx-value-layout="map"]))
    |> render_click()

    view
    |> element(~s(button[data-assignment-id="assign-active"]))
    |> render_click()

    html = render(view)
    assert html =~ "Assignment details"
    assert html =~ "Build alpha"
    assert html =~ ~r|<dt>Runtime</dt><dd>1m [0-9]+s</dd>|
    assert html =~ ~s(<dt>Total tokens</dt><dd>12</dd>)
    assert html =~ ~s(<dt>Input tokens</dt><dd>4</dd>)
    assert html =~ ~s(<dt>Output tokens</dt><dd>8</dd>)
    refute html =~ "<dd>1,803</dd>"
    assert html =~ ~s(href="https://github.com/org/repo-alpha/issues/11")
    assert html =~ ~s(target="_blank")
    refute html =~ "javascript:"

    view
    |> element(~s(button[data-assignment-id="assign-review"]))
    |> render_click()

    assert has_element?(view, ~s(button[data-assignment-id="assign-review"][aria-pressed]))

    html = render(view)
    assert html =~ ~s(<dt>Runtime</dt><dd>Not recorded</dd>)
    assert html =~ ~s(<dt>Total tokens</dt><dd>Not recorded</dd>)

    view
    |> element(~s(button[data-assignment-id="assign-active-idle"]))
    |> render_click()

    html = render(view)
    assert html =~ ~s(<dt>Runtime</dt><dd>2m 3s</dd>)
    assert html =~ ~s(<dt>Total tokens</dt><dd>55</dd>)
    assert html =~ ~s(<dt>Input tokens</dt><dd>21</dd>)
    assert html =~ ~s(<dt>Output tokens</dt><dd>34</dd>)

    view
    |> element(~s(button[data-assignment-id="assign-review"]))
    |> render_click()

    reviewed_state =
      managed_state
      |> put_in([:assignments, "assign-active", :phase], :review)
      |> put_in([:assignments, "assign-active", :status], "review")

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :managed_state, {:ok, reviewed_state})
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      has_element?(view, ~s([data-assignment-id="assign-active"])) and
        has_element?(view, ~s(button[data-assignment-id="assign-review"][aria-pressed]))
    end)

    accepted_state =
      reviewed_state
      |> put_in([:assignments, "assign-active", :phase], :accepted)
      |> put_in([:assignments, "assign-active", :status], "accepted")
      |> put_in([:assignments, "assign-active", :stop_pending], true)

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :managed_state, {:ok, accepted_state})
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      has_element?(view, ~s([data-assignment-id="assign-active"].task-accepted)) and
        has_element?(view, ~s(button[data-assignment-id="assign-review"][aria-pressed]))
    end)

    html = render(view)
    assert html =~ "Complete"
    assert html =~ "2 open · 1 complete"
    assert has_element?(view, ".task-node-activity", "Completed and retained in this PM's work")
    assert html =~ ~s(Live work<span>3</span>)
    refute has_element?(view, ~s([data-assignment-id="assign-active"].worker-running))
    refute html =~ "connection-running"

    view
    |> element(~s(button[phx-value-view="history"]))
    |> render_click()

    html = render(view)
    assert html =~ "Work history"
    assert html =~ "History PM"
    assert html =~ "Finished history"
    refute html =~ "PM One"
    refute html =~ "Build alpha"
    assert html =~ "Earlier unassigned work"
    assert has_element?(view, "#history-list")
    refute has_element?(view, ~s([data-assignment-id="assign-active"]))

    view
    |> element("button.manager-option", "History PM")
    |> render_click()

    assert has_element?(view, ~s([data-assignment-id="assign-accepted"]))
    html = render(view)
    assert html =~ ~s(data-metric="tokens">Tokens <strong>15</strong>)

    view
    |> element(~s(button[data-assignment-id="assign-accepted"]))
    |> render_click()

    html = render(view)
    assert html =~ ~s(<dt>Runtime</dt><dd>1m 4s</dd>)
    assert html =~ ~s(<dt>Total tokens</dt><dd>15</dd>)
    assert html =~ ~s(<dt>Input tokens</dt><dd>7</dd>)
    assert html =~ ~s(<dt>Output tokens</dt><dd>8</dd>)

    view
    |> element("button.manager-option", "Earlier unassigned work")
    |> render_click()

    assert render(view) =~ "Cancelled history"

    view
    |> element(~s(button[phx-value-view="runtime"]))
    |> render_click()

    html = render(view)
    assert html =~ "Runtime details"
    assert html =~ "Projects and repositories"
    assert html =~ "Project 4"
    assert html =~ "org/repo-alpha"
    assert html =~ "Ownership transfer history"
    assert html =~ "Handoff"
    assert html =~ "pm-one → pm-two"
    assert html =~ "operator → pm-one"
    assert html =~ "capacity"

    view
    |> element(~s(button[phx-value-view="live"]))
    |> render_click()

    view
    |> form("form.work-search")
    |> render_change(%{"query" => "idle"})

    html = render(view)
    assert html =~ "Phase active but idle"
    refute html =~ "Build alpha"

    view |> form("form.work-search") |> render_change(%{"query" => ""})

    completed_state =
      Enum.reduce(["assign-active-idle", "assign-review"], accepted_state, fn id, state ->
        state
        |> put_in([:assignments, id, :phase], :accepted)
        |> put_in([:assignments, id, :worker_active], false)
      end)

    :sys.replace_state(orchestrator_pid, fn state ->
      state
      |> Keyword.put(:managed_state, {:ok, completed_state})
      |> Keyword.put(:snapshot, put_in(dashboard_snapshot, [:running], []))
    end)

    StatusDashboard.notify_update()
    assert_eventually(fn -> render(view) =~ "0 open · 3 complete" end)
    assert has_element?(view, ~s([data-assignment-id="assign-active"].task-accepted))
    refute has_element?(view, ".worker-running")

    {:ok, reloaded_view, reloaded_html} = live(build_conn(), "/?pm=pm-one")
    assert reloaded_html =~ "0 open · 3 complete"
    assert has_element?(reloaded_view, ~s([data-assignment-id="assign-active"].task-accepted))

    {:ok, history_view, history_html} = live(build_conn(), "/?pm=pm-one&view=history")
    assert history_html =~ "Work history"
    assert history_html =~ "History PM"
    refute history_html =~ "Build alpha"
    assert has_element?(history_view, "#history-list")

    history_view |> element(~s(button[phx-value-view="live"])) |> render_click()
    assert render(history_view) =~ "0 open · 3 complete"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1, "blocked" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          issue_url: "https://example.org/issues/MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          issue_url: "https://example.org/issues/MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          issue_url: "https://example.org/issues/MT-BLOCKED",
          state: "In Progress",
          error: "codex turn requires operator input",
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-BLOCKED",
          session_id: "thread-blocked",
          blocked_at: DateTime.utc_now(),
          last_codex_event: :turn_input_required,
          last_codex_message: %{
            event: :turn_input_required,
            message: %{"method" => "turn/input_required"},
            timestamp: DateTime.utc_now()
          },
          last_codex_timestamp: DateTime.utc_now()
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
