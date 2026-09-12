defmodule SymphonyElixirWeb.PresenterManagedDashboardTest.StaticOrchestrator do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, Keyword.fetch!(state, :snapshot), state}
end

defmodule SymphonyElixirWeb.PresenterManagedDashboardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.Presenter
  alias SymphonyElixirWeb.PresenterManagedDashboardTest.StaticOrchestrator

  test "projects current V2 assignments and excludes terminal history from health and counts" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    terminal_projection_time = DateTime.add(now, -3_600, :second)
    running_started_at = DateTime.add(now, -75, :second)

    managed = %{
      revision: 9,
      cursor: 18,
      paused: false,
      disabled: false,
      max_concurrent_agents: 3,
      max_concurrent_agents_by_state: %{"ready" => 2},
      projects: %{},
      principals: %{
        "pm-one" => %{principal_id: "pm-one", display_name: "PM <One>", task_uuid: "task-pm-one"},
        "pm-two" => %{principal_id: "pm-two", display_name: "PM Two", task_uuid: "task-pm-two"}
      },
      assignments: %{
        "active" => %{
          assignment_id: "active",
          phase: :active,
          title: "Live task",
          ownership: %{pm_id: "pm-one", status: :owned, ownership_revision: 3},
          worker_id: "worker-1",
          worker_host: nil,
          worker_active: true,
          worker_activity: "<running & verifying>",
          turn_model: "gpt-5.6-luna",
          turn_effort: "xhigh",
          route: %{model: "gpt-5.6-terra", effort: "max"},
          started_at: terminal_projection_time,
          usage: %{
            input_tokens: 901,
            output_tokens: 902,
            total_tokens: 1_803,
            seconds_running: 9_999,
            accounting_status: :unavailable,
            historical_raw_tokens: %{input_tokens: 4_001, output_tokens: 4_002, total_tokens: 8_003}
          },
          last_report: %{
            kind: "checkpoint",
            summary: "<safe summary>",
            evidence: ["check passed", %{private: "must not be exposed"}]
          },
          reports: %{
            {"attempt-1", "report-1"} => %{attempt_id: "attempt-1", report_id: "report-1", kind: "checkpoint", summary: "first"},
            {"attempt-2", "report-2"} => %{attempt_id: "attempt-2", report_id: "report-2", kind: "result", summary: "second"}
          },
          review_feedback: %{peer_report_refs: [%{source_assignment_id: "peer", source_attempt_id: "peer-attempt", report_id: "peer-report"}]},
          pending_effect: %{kind: :provider_transition, status: :reconciled, at: now}
        },
        "queued" => %{
          assignment_id: "queued",
          phase: :ready,
          title: "Queued task",
          ownership: %{pm_id: "pm-two", status: :owned},
          worker_active: false,
          usage: %{
            input_tokens: 21,
            output_tokens: 34,
            total_tokens: 55,
            seconds_running: 123,
            accounting_status: :unreliable,
            historical_raw_tokens: %{input_tokens: 5_001, output_tokens: 5_002, total_tokens: 10_003}
          },
          turn_model: "gpt-5.6-luna",
          turn_effort: "xhigh",
          route: %{model: "gpt-5.6-terra", effort: "max"},
          pending_effect: %{kind: :run, status: :unknown, at: now}
        },
        "waiting" => %{
          assignment_id: "waiting",
          phase: :waiting,
          title: "Waiting task",
          ownership: %{pm_id: "pm-two", status: :owned},
          worker_active: false,
          blocked_reason: "<waiting for dependency>",
          last_report: %{kind: "context_needed", summary: "Need dependency", evidence: ["dependency missing"]}
        },
        "review" => %{
          assignment_id: "review",
          phase: :review,
          title: "Review task",
          ownership: %{pm_id: "pm-one", status: :owned},
          worker_active: false
        },
        "review-pending" => %{
          assignment_id: "review-pending",
          phase: :review_pending,
          title: "Pending review task",
          ownership: %{pm_id: "pm-one", status: :owned},
          worker_active: false
        },
        "accepted-history" => %{
          assignment_id: "accepted-history",
          phase: :accepted,
          ownership: %{pm_id: "pm-one", status: :owned},
          worker_active: true,
          usage: %{input_tokens: 7, output_tokens: 8, total_tokens: 15, seconds_running: 64},
          started_at: terminal_projection_time,
          projection: %{status: :failed, revision: 5, updated_at: terminal_projection_time, error: "old failure"}
        },
        "cancelled-history" => %{
          assignment_id: "cancelled-history",
          phase: :cancelled,
          ownership: %{status: :unassigned},
          projection: %{status: :failed, revision: 6, updated_at: terminal_projection_time, error: "old failure"}
        }
      }
    }

    snapshot = %{
      running: [
        %{
          issue_id: "active",
          identifier: "ACTIVE",
          issue_url: "https://example.org/issues/ACTIVE",
          state: "In Progress",
          session_id: "session-active",
          turn_count: 4,
          last_codex_event: :notification,
          last_codex_message: "live",
          last_codex_timestamp: now,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: running_started_at
        }
      ],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil,
      managed: managed
    }

    name = Module.concat(__MODULE__, String.to_atom("orchestrator_#{System.unique_integer([:positive])}"))
    {:ok, pid} = StaticOrchestrator.start_link(name: name, snapshot: snapshot)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    payload = Presenter.state_payload(name, 50)
    assignments = payload.managed.assignments

    assert assignments["active"].ownership.display_name == "PM <One>"
    assert assignments["active"].route == %{model: "gpt-5.6-luna", effort: "xhigh", source: "running"}
    assert assignments["queued"].route == %{model: "gpt-5.6-terra", effort: "max", source: "configured"}
    assert assignments["active"].started_at == DateTime.to_iso8601(terminal_projection_time)

    assert assignments["active"].usage == %{
             input_tokens: 901,
             output_tokens: 902,
             total_tokens: 1_803,
             seconds_running: 9_999,
             accounting_status: "unavailable",
             historical_raw_tokens: %{
               diagnostic: "unavailable",
               valid_spend: false,
               values: %{input_tokens: 4_001, output_tokens: 4_002, total_tokens: 8_003}
             }
           }

    assert assignments["queued"].usage == %{
             input_tokens: 21,
             output_tokens: 34,
             total_tokens: 55,
             seconds_running: 123,
             accounting_status: "unreliable",
             historical_raw_tokens: %{
               diagnostic: "unreliable",
               valid_spend: false,
               values: %{input_tokens: 5_001, output_tokens: 5_002, total_tokens: 10_003}
             }
           }

    assert assignments["accepted-history"].usage == %{
             input_tokens: 7,
             output_tokens: 8,
             total_tokens: 15,
             seconds_running: 64
           }

    assert assignments["active"].worker == %{
             id: "worker-1",
             host: nil,
             active: true,
             activity: "<running & verifying>"
           }

    assert assignments["active"].last_report == %{
             kind: "checkpoint",
             summary: "<safe summary>",
             evidence: ["check passed"]
           }

    assert Enum.map(assignments["active"].reports, & &1.report_id) |> Enum.sort() == ["report-1", "report-2"]
    assert assignments["active"].peer_report_refs == [%{source_assignment_id: "peer", source_attempt_id: "peer-attempt", report_id: "peer-report"}]

    assert assignments["waiting"].blocked_reason == "<waiting for dependency>"
    refute assignments["waiting"].worker.active
    refute assignments["review"].worker.active

    assert assignments["active"].projection.status == "synced"
    assert assignments["active"].projection.updated_at == DateTime.to_iso8601(now)
    assert assignments["queued"].projection.status == "unknown"
    refute assignments["queued"].projection.stale

    assert payload.managed.counts == %{running: 1, queued: 1, review: 2, waiting: 1, blocked: 1}
    assert payload.managed.diagnostics.concurrency == %{global: 3, by_state: %{"ready" => 2}, fallback: 3}
    assert payload.managed.projection.errors == []
    refute payload.managed.projection.stale
  end
end
