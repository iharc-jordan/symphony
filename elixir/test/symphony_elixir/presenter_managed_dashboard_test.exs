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

    managed = %{
      revision: 9,
      cursor: 18,
      paused: false,
      disabled: false,
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
          worker_host: "node-a",
          worker_active: true,
          worker_activity: "<running & verifying>",
          turn_model: "gpt-5.6-luna",
          turn_effort: "xhigh",
          route: %{model: "gpt-5.6-terra", effort: "max"},
          started_at: now,
          last_report: %{
            kind: "checkpoint",
            summary: "<safe summary>",
            evidence: ["check passed", %{private: "must not be exposed"}]
          },
          pending_effect: %{kind: :provider_transition, status: :reconciled, at: now}
        },
        "queued" => %{
          assignment_id: "queued",
          phase: :ready,
          title: "Queued task",
          ownership: %{pm_id: "pm-two", status: :owned},
          worker_active: false,
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
        "accepted-history" => %{
          assignment_id: "accepted-history",
          phase: :accepted,
          ownership: %{pm_id: "pm-one", status: :owned},
          worker_active: true,
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
      running: [],
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
    assert assignments["active"].started_at == DateTime.to_iso8601(now)

    assert assignments["active"].worker == %{
             id: "worker-1",
             host: "node-a",
             active: true,
             activity: "<running & verifying>"
           }

    assert assignments["active"].last_report == %{
             kind: "checkpoint",
             summary: "<safe summary>",
             evidence: ["check passed"]
           }

    assert assignments["waiting"].blocked_reason == "<waiting for dependency>"
    refute assignments["waiting"].worker.active
    refute assignments["review"].worker.active

    assert assignments["active"].projection.status == "synced"
    assert assignments["active"].projection.updated_at == DateTime.to_iso8601(now)
    assert assignments["queued"].projection.status == "unknown"
    refute assignments["queued"].projection.stale

    assert payload.managed.counts == %{running: 1, queued: 1, review: 1, waiting: 1, blocked: 1}
    assert payload.managed.projection.errors == []
    refute payload.managed.projection.stale
  end
end
