defmodule SymphonyElixirWeb.ManagedStateViewTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.ManagedStateView

  @pm "pm-a"
  @other_pm "pm-b"

  test "summary scopes PMs to owned work and keeps terminal siblings beside active work" do
    report = %{
      report_id: "report-1",
      kind: "checkpoint",
      summary: String.duplicate("x", 600),
      evidence: [%{secret: "omitted from summary"}],
      source: "worker",
      attempt_id: "attempt-1"
    }

    state =
      state_with_assignments(%{
        "active" => assignment("active", "PVT_one", @pm, :ready, last_report: report),
        "accepted-sibling" => assignment("accepted-sibling", "PVT_one", @pm, :accepted),
        "terminal-only" => assignment("terminal-only", "PVT_two", @pm, :cancelled),
        "other-owner" => assignment("other-owner", "PVT_one", @other_pm, :active)
      })

    assert {:ok, payload} = ManagedStateView.project(state, pm(@pm), %{})

    assert Map.keys(payload.assignments) |> Enum.sort() == ["accepted-sibling", "active", "terminal-only"]
    assert Map.keys(payload.projects) |> Enum.sort() == ["PVT_one", "PVT_two"]
    assert payload.principal.principal_id == @pm
    assert payload.revision == 8
    assert payload.control_revision == 8
    assert payload.cursor == 14

    summary = payload.assignments["active"].last_report
    assert summary.report_id == "report-1"
    assert summary.source == "worker"
    assert summary.attempt_id == "attempt-1"
    assert payload.assignments["active"].attempt.attempt_id == "attempt-active"
    assert payload.assignments["active"].attempt.revision == 1
    assert byte_size(summary.summary) == 500
    refute Map.has_key?(summary, :evidence)
    assert payload.usage["future_unknown"] == true
  end

  test "explicit project inspection includes active and terminal records from the project" do
    state =
      state_with_assignments(%{
        "active-other" => assignment("active-other", "PVT_one", @other_pm, :active),
        "accepted-other" => assignment("accepted-other", "PVT_one", @other_pm, :accepted)
      })

    assert {:ok, payload} = ManagedStateView.project(state, pm(@pm), %{project_id: "PVT_one"})
    assert Map.keys(payload.assignments) |> Enum.sort() == ["accepted-other", "active-other"]
  end

  test "wait reason uses supplied live capacity facts without exposing them" do
    state =
      state_with_assignments(%{
        "ready" => assignment("ready", "PVT_one", @pm, :ready)
      })

    options = %{
      view: :summary,
      project_id: nil,
      assignment_id: nil,
      include_history: false,
      runtime_facts: %{max_concurrent_agents: 1, running_count: 1}
    }

    assert {:ok, payload} = ManagedStateView.project(state, pm(@pm), options)
    assert payload.assignments["ready"].wait_reason == "concurrency_limit"

    limited = Map.put(state, :usage_limit_tokens, 10_000)
    assert ManagedStateView.wait_reason(state.assignments["ready"], limited, %{}) == "usage_accounting_unavailable"

    reached = put_in(limited, [:usage], %{accounting_status: :known, cap_reached: true})
    assert ManagedStateView.wait_reason(state.assignments["ready"], reached, %{}) == "usage_limit_reached"
    refute Map.has_key?(payload, :runtime_facts)
  end

  test "summary running count and worker activity require explicit worker evidence" do
    state =
      state_with_assignments(%{
        "phase-active" => assignment("phase-active", "PVT_one", @pm, :active),
        "worker-active" => assignment("worker-active", "PVT_one", @pm, :ready, worker_active: true)
      })

    assert {:ok, payload} = ManagedStateView.project(state, pm(@pm), %{})
    assert payload.counts.running == 1
    assert payload.assignments["phase-active"].worker.active == false
    assert payload.assignments["worker-active"].worker.active == true
  end

  test "review and review_pending share one review count and diagnostics expose limit fallback" do
    state =
      state_with_assignments(%{
        "review" => assignment("review", "PVT_one", @pm, :review),
        "review-pending" => assignment("review-pending", "PVT_one", @pm, :review_pending),
        "ready" => assignment("ready", "PVT_one", @pm, :ready)
      })

    assert {:ok, payload} =
             ManagedStateView.project(state, pm(@pm), %{
               view: :summary,
               project_id: nil,
               assignment_id: nil,
               include_history: false,
               runtime_facts: %{max_concurrent_agents: 3, max_concurrent_agents_by_state: %{"ready" => 2, "zero" => 0}}
             })

    assert payload.counts.review == 2
    assert payload.diagnostics.concurrency == %{global: 3, by_state: %{"ready" => 2}, fallback: 3}
    assert payload.usage["baseline_tokens"] == 10
    assert payload.usage["cumulative_tokens"] == 20

    assert {:ok, invalid_limits} =
             ManagedStateView.project(state, pm(@pm), %{
               view: :summary,
               project_id: nil,
               assignment_id: nil,
               include_history: false,
               runtime_facts: %{max_concurrent_agents: 3, max_concurrent_agents_by_state: :invalid}
             })

    assert invalid_limits.diagnostics.concurrency.by_state == %{}
  end

  test "operator history keeps siblings for active PMs and omits terminal-only PM groups" do
    state =
      state_with_assignments(%{
        "active-a" => assignment("active-a", "PVT_one", @pm, :active),
        "completed-a" => assignment("completed-a", "PVT_two", @pm, :accepted),
        "completed-b" => assignment("completed-b", "PVT_three", @other_pm, :cancelled),
        "active-b" => assignment("active-b", "PVT_three", @other_pm, :active)
      })

    assert {:ok, payload} = ManagedStateView.project(state, %{principal_id: "operator", role: :operator}, %{})
    assert Map.keys(payload.assignments) |> Enum.sort() == ["active-a", "active-b", "completed-a", "completed-b"]

    state = put_in(state, [:assignments, "active-b", :phase], :accepted)
    assert {:ok, payload} = ManagedStateView.project(state, %{principal_id: "operator", role: :operator}, %{})
    assert Map.keys(payload.assignments) |> Enum.sort() == ["active-a", "completed-a"]
  end

  test "history and explicit assignment preserve completed records" do
    state =
      state_with_assignments(%{
        "completed" => assignment("completed", "PVT_one", @pm, :accepted),
        "other" => assignment("other", "PVT_two", @other_pm, :cancelled)
      })

    assert {:ok, history} =
             ManagedStateView.project(state, pm(@pm), %{
               "include_history" => "true"
             })

    assert Map.has_key?(history.assignments, "completed")
    refute Map.has_key?(history.assignments, "other")

    assert {:ok, explicit} =
             ManagedStateView.project(state, pm(@pm), %{
               "assignment_id" => "completed"
             })

    assert Map.keys(explicit.assignments) == ["completed"]
  end

  test "detail requires an assignment and keeps full report evidence and current metadata" do
    report = %{report_id: "r-1", kind: "result", summary: "done", evidence: [%{commit: "abc"}]}

    assignment =
      assignment("a-1", "PVT_one", @pm, :review,
        reports: %{"r-1" => report},
        last_report: report,
        attempt_id: "attempt-2",
        review_feedback: %{peer_report_refs: [%{source_assignment_id: "source", source_attempt_id: "source-attempt", report_id: "source-report"}]}
      )

    assert {:error, {:assignment_id, message}} =
             ManagedStateView.project(state_with_assignments(%{"a-1" => assignment}), pm(@pm), %{
               "view" => "detail"
             })

    assert message =~ "required"

    assert {:ok, payload} =
             ManagedStateView.project(state_with_assignments(%{"a-1" => assignment}), pm(@pm), %{
               "view" => "detail",
               "assignment_id" => "a-1"
             })

    assert payload.assignment.reports["r-1"].evidence == [%{commit: "abc"}]
    assert payload.assignment.peer_report_refs == [%{source_assignment_id: "source", source_attempt_id: "source-attempt", report_id: "source-report"}]
    assert payload.assignment.attempt_id == "attempt-2"
    assert payload.assignment.wait_reason == nil
  end

  test "ready wait reason follows known service, stop, dependency, and capacity facts" do
    assignments = %{
      "disabled" => assignment("disabled", "PVT_one", @pm, :ready),
      "stopped" => assignment("stopped", "PVT_one", @pm, :ready, stop_pending: true),
      "blocked" => assignment("blocked", "PVT_one", @pm, :ready, dependencies: ["dependency"]),
      "dependency" => assignment("dependency", "PVT_one", @pm, :active),
      "ready" => assignment("ready", "PVT_one", @pm, :ready)
    }

    state = state_with_assignments(assignments)

    assert {:ok, payload} = ManagedStateView.project(%{state | disabled: true}, pm(@pm), %{})
    assert payload.assignments["disabled"].wait_reason == "managed_mode_disabled"

    assert {:ok, payload} = ManagedStateView.project(%{state | paused: true}, pm(@pm), %{})
    assert payload.assignments["disabled"].wait_reason == "service_paused"

    assert {:ok, payload} = ManagedStateView.project(state, pm(@pm), %{})
    assert payload.assignments["stopped"].wait_reason == "stop_pending"
    assert payload.assignments["blocked"].wait_reason == "dependencies_not_accepted"
    assert payload.assignments["ready"].wait_reason == "ready"
    assert payload.usage["accounting_status"] == "unavailable"

    assert payload.usage["historical_raw_tokens"] == %{
             diagnostic: "unavailable",
             valid_spend: false,
             values: %{"input" => 41, "output" => 59}
           }

    saturated = Map.merge(state, %{max_concurrent_agents: 1, running: %{"worker" => %{}}})
    assert {:ok, payload} = ManagedStateView.project(saturated, pm(@pm), %{})
    assert payload.assignments["ready"].wait_reason == "concurrency_limit"
  end

  test "full view retains the explicit diagnostic snapshot shape" do
    state =
      state_with_assignments(%{
        "a-1" => assignment("a-1", "PVT_one", @pm, :active, reports: %{"r" => %{evidence: ["proof"]}})
      })
      |> Map.put(:events, [%{cursor: 14, operation: :enroll}])
      |> Map.put(:diagnostic, %{all: :terms})

    assert {:ok, payload} =
             ManagedStateView.project(state, pm(@pm), %{
               "view" => "full",
               "assignment_id" => "a-1"
             })

    assert payload.view == "full"
    assert payload.events == [%{cursor: 14, operation: :enroll}]
    assert payload.diagnostic == %{all: :terms}
    assert payload.assignments["a-1"].reports == %{"r" => %{evidence: ["proof"]}}
  end

  test "invalid query parameters return field-specific errors" do
    assert {:error, {:view, _}} = ManagedStateView.parse_params(%{"view" => "compact"})
    assert {:error, {:include_history, _}} = ManagedStateView.parse_params(%{"include_history" => "yes"})
    assert {:error, {:project_id, _}} = ManagedStateView.parse_params(%{"project_id" => ""})
  end

  test "parse accepts all supported query forms and rejects malformed values" do
    assert {:error, {:params, _}} = ManagedStateView.parse_params(:malformed)
    assert {:ok, %{view: :summary, include_history: false}} = ManagedStateView.parse_params(%{})
    assert {:ok, %{view: :summary, include_history: false}} = ManagedStateView.parse_params(%{"view" => " SUMMARY "})
    assert {:ok, %{view: :detail, include_history: true}} = ManagedStateView.parse_params(%{"view" => "detail", "include_history" => "true"})
    assert {:ok, %{view: :full, include_history: false}} = ManagedStateView.parse_params(%{"view" => :full, "include_history" => false})

    assert {:error, {:view, _}} = ManagedStateView.parse_params(%{"view" => 1})
    assert {:error, {:project_id, _}} = ManagedStateView.parse_params(%{"project_id" => 1})
    assert {:error, {:assignment_id, _}} = ManagedStateView.parse_params(%{"assignment_id" => 1})
    assert {:error, {:include_history, _}} = ManagedStateView.parse_params(%{"include_history" => 1})
    assert {:error, {:include_history, _}} = ManagedStateView.parse_params(%{"include_history" => "maybe"})
    assert {:ok, %{include_history: false}} = ManagedStateView.parse_params(%{"include_history" => " FALSE "})
  end

  test "projection handles malformed records and preserves explicit project diagnostics" do
    now = DateTime.utc_now()

    malformed_project = %{
      project_id: "PVT_bad",
      project_number: %{},
      status_field_id: [:bad],
      status_field_name: :status,
      owner: 17,
      owner_type: false,
      repositories: :not_a_list,
      status_options: %{{:bad_key} => 1, "missing" => %{}, "ok" => 2, "atom" => :ready},
      revision: "not_an_integer"
    }

    malformed_usage = %{
      nil => 1,
      baseline_tokens: nil,
      future_atom: :diagnostic,
      unsupported: {:tuple},
      historical_raw_tokens: %{nil => 1, "input" => 4, "bad" => "not-a-number"}
    }

    assignments = %{
      "bare" => %{project_id: "PVT_bad", ownership: :owned, report_id: "fallback-report", report_source: "fallback-source"},
      "reports" =>
        assignment("reports", "PVT_bad", @pm, :ready,
          last_report: %{summary: :atom},
          usage: malformed_usage,
          started_at: now,
          updated_at: "2026-09-11T12:00:00Z"
        ),
      "report-int" => assignment("report-int", "PVT_bad", @pm, :ready, last_report: %{summary: 42}),
      "report-float" => assignment("report-float", "PVT_bad", @pm, :ready, last_report: %{summary: 4.2}),
      "report-bool" => assignment("report-bool", "PVT_bad", @pm, :ready, last_report: %{summary: true}),
      "report-other" => assignment("report-other", "PVT_bad", @pm, :ready, last_report: %{summary: %{nested: true}}),
      "bad-report" => assignment("bad-report", "PVT_bad", @pm, :ready, last_report: :malformed),
      "bad-history" => assignment("bad-history", "PVT_bad", @pm, :ready, usage: %{historical_raw_tokens: :malformed}),
      "bad-time" => assignment("bad-time", "PVT_bad", @pm, :ready, started_at: "not-a-timestamp", updated_at: :bad),
      "dispatch-paused" => assignment("dispatch-paused", "PVT_bad", @pm, :ready, dispatch_paused: true),
      "dependency-missing" => assignment("dependency-missing", "PVT_bad", @pm, :ready, dependencies: [%{assignment_id: "missing"}]),
      "dependency-accepted" => assignment("dependency-accepted", "PVT_bad", @pm, :ready, dependencies: ["accepted"]),
      "accepted" => assignment("accepted", "PVT_bad", @pm, :accepted)
    }

    state =
      state_with_assignments(assignments)
      |> Map.merge(%{
        projects: %{"PVT_bad" => malformed_project, "PVT_opaque" => :opaque},
        usage: malformed_usage,
        revision: "missing",
        control_revision: 3,
        cursor: "missing",
        event_cursor: 9,
        usage_limit_tokens: "not-an-integer"
      })

    assert {:ok, payload} = ManagedStateView.project(state, pm(@pm), %{project_id: "PVT_bad"})
    assert payload.projects["PVT_bad"].project_id == "PVT_bad"
    assert payload.projects["PVT_bad"].status_options == %{"ok" => 2, "atom" => "ready"}
    assert payload.assignments["reports"].last_report.summary == "atom"
    assert payload.assignments["reports"].started_at == DateTime.to_iso8601(now)
    assert payload.assignments["reports"].updated_at == "2026-09-11T12:00:00Z"
    assert payload.assignments["bare"].status == "unknown"
    assert payload.assignments["bare"].ownership.status == "owned"
    assert payload.assignments["dispatch-paused"].wait_reason == "assignment_paused"
    assert payload.assignments["dependency-missing"].wait_reason == "dependencies_not_accepted"
    assert payload.assignments["dependency-accepted"].wait_reason == "ready"
    assert payload.usage["future_atom"] == "diagnostic"

    assert payload.usage["historical_raw_tokens"] == %{
             diagnostic: "unavailable",
             valid_spend: false,
             values: %{"input" => 4}
           }

    known_usage = %{accounting_status: :known, historical_raw_tokens: %{input: 99}}
    assert {:ok, known_payload} = ManagedStateView.project(Map.put(state, :usage, known_usage), pm(@pm), %{project_id: "PVT_bad"})
    refute Map.has_key?(known_payload.usage, "historical_raw_tokens")

    assert {:ok, filtered_full} =
             ManagedStateView.project(state, pm(@pm), %{"view" => "full", "project_id" => "PVT_bad"})

    assert Map.keys(filtered_full.projects) |> Enum.sort() == ["PVT_bad"]
    assert filtered_full.assignments["bare"].project_id == "PVT_bad"

    assert {:ok, opaque_full} =
             ManagedStateView.project(state, pm(@pm), %{"view" => "full", "project_id" => "PVT_opaque"})

    assert opaque_full.projects["PVT_opaque"] == :opaque

    assert {:ok, opaque_summary} = ManagedStateView.project(state, pm(@pm), %{project_id: "PVT_opaque"})
    assert opaque_summary.projects["PVT_opaque"] == %{project_id: "PVT_opaque"}
  end

  test "projection supports fallback capacity sources and malformed collections" do
    state =
      state_with_assignments(%{
        "ready" => assignment("ready", "PVT_one", @pm, :ready),
        "detail-fallback" => %{project_id: "PVT_one", ownership: %{pm_id: @pm}, phase: :review}
      })
      |> Map.merge(%{projects: [], assignments: [], usage: :invalid, max_concurrent_agents: 1, running: [%{}]})

    assert {:ok, payload} = ManagedStateView.project(state, pm(@pm))
    assert payload.projects == %{}
    assert payload.assignments == %{}

    list_running_state =
      state_with_assignments(%{"ready" => assignment("ready", "PVT_one", @pm, :ready)})
      |> Map.merge(%{max_concurrent_agents: 1, running: [%{}]})

    assert {:ok, payload} = ManagedStateView.project(list_running_state, pm(@pm))
    assert payload.assignments["ready"].wait_reason == "concurrency_limit"

    fallback_state =
      state_with_assignments(%{"ready" => assignment("ready", "PVT_one", @pm, :ready)})
      |> Map.merge(%{projects: %{}, max_concurrent_agents: nil, running: :unknown, runtime: %{max_agents: 1, running_count: 1}})

    assert {:ok, payload} = ManagedStateView.project(fallback_state, pm(@pm))
    assert payload.assignments["ready"].wait_reason == "concurrency_limit"

    runtime_state =
      state_with_assignments(%{"ready" => assignment("ready", "PVT_one", @pm, :ready)})
      |> Map.merge(%{projects: %{}, max_concurrent_agents: nil, running: nil, runtime: %{max_concurrent_agents: 1, running_count: 1}})

    assert {:ok, payload} = ManagedStateView.project(runtime_state, pm(@pm))
    assert payload.assignments["ready"].wait_reason == "concurrency_limit"

    runtime_map_state =
      state_with_assignments(%{"ready" => assignment("ready", "PVT_one", @pm, :ready)})
      |> Map.merge(%{max_concurrent_agents: 1, running: nil})

    assert {:ok, payload} =
             ManagedStateView.project(runtime_map_state, pm(@pm), %{
               view: :summary,
               project_id: nil,
               assignment_id: nil,
               include_history: false,
               runtime_facts: %{running: %{"worker" => %{}}}
             })

    assert payload.assignments["ready"].wait_reason == "concurrency_limit"

    runtime_list_state =
      state_with_assignments(%{"ready" => assignment("ready", "PVT_one", @pm, :ready)})
      |> Map.merge(%{max_concurrent_agents: 1, running: nil})

    assert {:ok, payload} =
             ManagedStateView.project(runtime_list_state, pm(@pm), %{
               view: :summary,
               project_id: nil,
               assignment_id: nil,
               include_history: false,
               runtime_facts: %{running: [%{}]}
             })

    assert payload.assignments["ready"].wait_reason == "concurrency_limit"

    runtime_invalid_state =
      state_with_assignments(%{"ready" => assignment("ready", "PVT_one", @pm, :ready)})
      |> Map.merge(%{max_concurrent_agents: 1, running: nil})

    assert {:ok, payload} =
             ManagedStateView.project(runtime_invalid_state, pm(@pm), %{
               view: :summary,
               project_id: nil,
               assignment_id: nil,
               include_history: false,
               runtime_facts: %{running: :unknown}
             })

    assert payload.assignments["ready"].wait_reason == "ready"

    assert ManagedStateView.wait_reason(%{phase: :review}, %{}, %{}) == nil
  end

  test "project and detail projections cover empty and missing records" do
    state = state_with_assignments(%{"known" => assignment("known", "PVT_one", @pm, :ready)})

    assert {:error, {:params, _}} = ManagedStateView.project(state, pm(@pm), :malformed)

    assert {:error, {:assignment_not_found, "unknown"}} =
             ManagedStateView.project(state, pm(@pm), %{
               view: :detail,
               assignment_id: "unknown",
               project_id: nil,
               include_history: false
             })

    assert {:ok, payload} =
             ManagedStateView.project(state, pm(@pm), %{
               view: :detail,
               assignment_id: "known",
               project_id: nil,
               include_history: false
             })

    assert payload.project.project_id == "PVT_one"
    assert ManagedStateView.project(%{assignments: :invalid, projects: :invalid}, pm(@pm)) |> elem(0) == :ok

    fallback_assignment = %{project_id: "PVT_one", ownership: %{pm_id: @pm}, phase: :review}

    assert {:ok, fallback_payload} =
             ManagedStateView.project(%{projects: %{}, assignments: %{"fallback" => fallback_assignment}}, pm(@pm), %{
               view: :detail,
               assignment_id: "fallback",
               project_id: nil,
               include_history: false
             })

    assert fallback_payload.assignment.assignment_id == nil
  end

  defp state_with_assignments(assignments) do
    %{
      version: 2,
      control_revision: 8,
      event_cursor: 14,
      revision: 8,
      cursor: 14,
      paused: false,
      disabled: false,
      usage_limit_tokens: nil,
      usage: %{
        baseline_tokens: 10,
        cumulative_tokens: 20,
        accounting_status: :unavailable,
        future_unknown: true,
        historical_raw_tokens: %{input: 41, output: 59}
      },
      projects: %{
        "PVT_one" => %{project_id: "PVT_one", project_number: 1, repositories: ["acme/one"], revision: 2},
        "PVT_two" => %{project_id: "PVT_two", project_number: 2, repositories: ["acme/two"], revision: 1}
      },
      assignments: assignments
    }
  end

  defp assignment(id, project_id, pm_id, phase, opts \\ []) do
    Map.merge(
      %{
        assignment_id: id,
        project_id: project_id,
        repository: "acme/one",
        issue_number: 1,
        title: id,
        phase: phase,
        board_state: phase,
        revision: 1,
        ownership: %{status: :owned, pm_id: pm_id, ownership_revision: 1},
        resources: [%{kind: :repository}],
        dependencies: [],
        route: %{model: "gpt-5.6-luna", effort: "xhigh"},
        reports: %{},
        attempt_id: "attempt-#{id}"
      },
      Map.new(opts)
    )
  end

  defp pm(id), do: %{principal_id: id, role: :pm, project_scope: :all}
end
