defmodule SymphonyElixir.ManagedRulesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.Rules

  defp envelope(id, operation, args), do: %{request_id: id, operation: operation, args: args}

  defp binding_args(expected_revision \\ 0) do
    %{
      expected_revision: expected_revision,
      project: %{
        project_id: "PVT_kwDO",
        project_number: 7,
        status_field_id: "PVTSSF",
        status_options: %{
          "READY" => "opt-ready",
          "ACTIVE" => "opt-active",
          "REVIEW" => "opt-review",
          "ACCEPTED" => "opt-accepted",
          "WAITING" => "opt-waiting",
          "CANCELLED" => "opt-cancelled"
        },
        repositories: ["acme/example"]
      }
    }
  end

  defp enrollment_args(id, expected_revision, opts \\ []) do
    %{
      expected_revision: expected_revision,
      assignment_id: id,
      repository: "acme/example",
      issue_number: Keyword.get(opts, :issue_number, 12),
      base_commit: "abc123",
      board_state: "READY",
      resources: Keyword.get(opts, :resources, ["repo:acme/example"]),
      dependencies: Keyword.get(opts, :dependencies, []),
      route: Keyword.get(opts, :route, %{model: "gpt-5.6-luna", effort: "xhigh"})
    }
    |> maybe_put(:requirements, Keyword.get(opts, :requirements))
    |> maybe_put(:requirements_fingerprint, Keyword.get(opts, :requirements_fingerprint))
    |> maybe_put(:requirements_revision, Keyword.get(opts, :requirements_revision))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp bound_state do
    {:ok, state, _response} =
      Rules.apply(Rules.new(), envelope("bind-1", :bind_project, binding_args()))

    state
  end

  defp enrolled_state(id, opts \\ []) do
    state = bound_state()

    {:ok, state, _response} =
      Rules.apply(state, envelope("enroll-" <> id, :enroll, enrollment_args(id, 1, opts)))

    state
  end

  test "normalizes known phases without creating atoms from input" do
    assert Rules.phase("READY") == :ready
    assert Rules.phase("in-progress") == :active
    assert Rules.phase("blocked") == :waiting
    assert Rules.phase("rework") == :rework
    assert Rules.phase("attacker_supplied_atom_name") == :unknown
    assert Rules.phase(:attacker_supplied_atom_name) == :unknown
  end

  test "review dispositions map rework to READY and blocked to WAITING" do
    state =
      enrolled_state("issue-1")
      |> put_in([:assignments, "issue-1", :phase], :review)
      |> put_in([:assignments, "issue-1", :board_state], :review)
      |> put_in([:assignments, "issue-1", :revision], 2)

    rework =
      envelope("review-rework", :review, %{
        assignment_id: "issue-1",
        expected_revision: 2,
        disposition: "rework",
        reason: "needs changes"
      })

    assert {:ok, intent} = Rules.prepare_review(state, rework)
    assert intent.disposition == :rework
    refute intent.requires_effects

    assert {:ok, reworked, rework_response} = Rules.apply(state, rework)
    assert rework_response.phase == :ready
    assert reworked.assignments["issue-1"].phase == :ready
    assert reworked.assignments["issue-1"].board_state == :ready

    blocked =
      envelope("review-blocked", :review, %{
        assignment_id: "issue-1",
        expected_revision: 2,
        disposition: "blocked",
        reason: "waiting on dependency"
      })

    assert {:ok, blocked_state, blocked_response} = Rules.apply(state, blocked)
    assert blocked_response.phase == :waiting
    assert blocked_state.assignments["issue-1"].phase == :waiting
    assert blocked_state.assignments["issue-1"].board_state == :waiting
  end

  test "request ids replay the recorded response and reject changed input" do
    state = bound_state()
    request = envelope("same-id", :enroll, enrollment_args("issue-1", 1))

    assert {:ok, next_state, response} = Rules.apply(state, request)
    assert {:duplicate, duplicate_response} = Rules.apply(next_state, request)
    assert Map.put(response, :duplicate, true) == Map.put(duplicate_response, :duplicate, true)

    changed = envelope("same-id", :enroll, enrollment_args("issue-2", 2))
    assert {:error, :request_id_conflict, %{request_id: "same-id"}} = Rules.apply(next_state, changed)
  end

  test "enrollment enforces repository, identity, and exclusive resources" do
    state = enrolled_state("issue-1")

    assert {:error, :duplicate_underlying_identity, %{assignment_id: "issue-1"}} =
             Rules.apply(state, envelope("enroll-2", :enroll, enrollment_args("issue-2", 2)))

    assert {:error, :resource_conflict, %{assignment_id: "issue-1"}} =
             Rules.apply(
               state,
               envelope("enroll-3", :enroll, enrollment_args("issue-3", 2, issue_number: 13))
             )
  end

  test "full issue requirements are never persisted without a material fingerprint" do
    state = bound_state()

    assert {:error, :requirements_fingerprint_required, %{}} =
             Rules.apply(
               state,
               envelope(
                 "enroll-requirements-without-fingerprint",
                 :enroll,
                 enrollment_args("issue-1", 1, requirements: %{"secret" => "body"})
               )
             )

    args =
      enrollment_args("issue-1", 1,
        requirements: %{"secret" => "body"},
        requirements_fingerprint: "sha256:body",
        requirements_revision: 4
      )

    assert {:ok, next_state, _} = Rules.apply(state, envelope("enroll-with-fingerprint", :enroll, args))
    assignment = next_state.assignments["issue-1"]
    refute Map.has_key?(assignment, :requirements)
    assert assignment.requirements_fingerprint == "sha256:body"
    assert assignment.requirements_revision == 4

    changed_body = put_in(args, [:requirements, "secret"], "different")

    assert Rules.canonical_input(%{request_id: "r", operation: :enroll, args: args}) ==
             Rules.canonical_input(%{request_id: "r", operation: :enroll, args: changed_body})
  end

  test "review acceptance requires provider and reconciled effect facts from service context" do
    state =
      enrolled_state("issue-1")
      |> put_in([:assignments, "issue-1", :phase], :review)
      |> put_in([:assignments, "issue-1", :board_state], :review)
      |> put_in([:assignments, "issue-1", :revision], 2)

    args = %{assignment_id: "issue-1", expected_revision: 2, disposition: "accepted", evidence: ["test log"]}

    assert {:error, :provider_state_not_review, %{}} =
             Rules.apply(state, envelope("review-no-proof", :review, Map.put(args, :provider_state, "review")))

    context = %{
      provider_state: :review,
      reconciled: true,
      external_effects: %{status: :ok, issue_close: :ok}
    }

    assert {:ok, accepted, response} = Rules.apply(state, envelope("review-ok", :review, args), context)
    assert accepted.assignments["issue-1"].phase == :accepted
    assert accepted.assignments["issue-1"].revision == 3
    assert response.issue_close == :ok
  end

  test "revision ignores caller stop proof and requires service reconciliation for active work" do
    state =
      enrolled_state("issue-1")
      |> put_in([:assignments, "issue-1", :phase], :active)
      |> put_in([:assignments, "issue-1", :board_state], :active)
      |> put_in([:assignments, "issue-1", :revision], 2)

    request =
      envelope("revise-active", :revise, %{
        assignment_id: "issue-1",
        expected_revision: 2,
        stop_reconciled: true,
        changes: %{route: %{model: "gpt-5.6-terra", effort: "max"}, escalation_reason: "fixture escalation"}
      })

    assert {:error, :active_assignment_stop_required, %{}} = Rules.apply(state, request)

    assert {:ok, revised, _} =
             Rules.apply(state, request, %{stop_reconciled: true})

    assert revised.assignments["issue-1"].phase == :ready
    assert revised.assignments["issue-1"].revision == 3
  end

  test "revision whitelists editable fields and rejects runtime or proof fields" do
    state =
      enrolled_state("issue-1")
      |> put_in([:assignments, "issue-1", :phase], :waiting)
      |> put_in([:assignments, "issue-1", :board_state], :waiting)
      |> put_in([:assignments, "issue-1", :revision], 2)

    request =
      envelope("revise-runtime-field", :revise, %{
        assignment_id: "issue-1",
        expected_revision: 2,
        changes: %{route: %{model: "gpt-5.6-terra", effort: "max"}, escalation_reason: "fixture escalation", stop_pending: false}
      })

    assert {:error, :invalid_argument, %{argument: :changes, fields: [:stop_pending]}} =
             Rules.apply(state, request)

    body_request =
      envelope("revise-requirements", :revise, %{
        assignment_id: "issue-1",
        expected_revision: 2,
        changes: %{
          requirements: %{"secret" => "body"},
          requirements_fingerprint: "sha256:body",
          requirements_revision: 3
        }
      })

    assert {:ok, revised, _response} = Rules.apply(state, body_request)
    refute Map.has_key?(revised.assignments["issue-1"], :requirements)
    assert revised.assignments["issue-1"].requirements_fingerprint == "sha256:body"
  end

  test "stop-pending assignments continue to hold resources" do
    state =
      enrolled_state("issue-1")
      |> put_in([:assignments, "issue-1", :phase], :waiting)
      |> put_in([:assignments, "issue-1", :stop_pending], true)

    assert {:error, :resource_conflict, %{assignment_id: "issue-1"}} =
             Rules.apply(
               state,
               envelope("enroll-2", :enroll, enrollment_args("issue-2", 2, issue_number: 13))
             )
  end

  test "public rule APIs reject malformed requests and cover lifecycle guards" do
    assert Rules.version() == 1
    assert :bind_project in Rules.allowed_operations()
    assert Rules.phase(123) == :unknown
    assert Rules.validate_route(%{model: "gpt-5.6-luna", effort: "xhigh"}) == :ok
    assert {:error, :invalid_route, %{}} = Rules.validate_route(:bad, nil)

    assert {:error, :invalid_route, %{model: "wat", effort: "max"}} =
             Rules.validate_route(%{model: "wat", effort: "max"})

    assert {:error, :route_escalation_reason_required, %{}} =
             Rules.validate_route(%{model: "gpt-5.6-terra", effort: "max"})

    assert {:error, :invalid_phase_transition, %{from: :ready, to: :review}} =
             Rules.validate_transition(:ready, :review)

    assert :ok = Rules.validate_transition(:idle, :bound)
    assert :ok = Rules.validate_transition(:bound, :ready)
    assert :ok = Rules.validate_transition(:active, :review)

    assert {:error, :invalid_phase_transition, %{from: :waiting, to: :waiting}} =
             Rules.validate_transition(:waiting, :waiting)

    assert {:error, :invalid_phase_transition, %{from: :accepted, to: :ready}} =
             Rules.validate_transition(:accepted, :ready)

    assert {:error, :invalid_phase_transition, %{from: :cancelled, to: :ready}} =
             Rules.validate_transition(:cancelled, :ready)

    assert {:error, :invalid_phase_transition, %{from: :unknown, to: :ready}} =
             Rules.validate_transition(:unknown, :ready)

    assert {:error, :expected_revision_required, %{}} = Rules.expected_revision(Rules.new(), %{}, :global)

    assert {:error, :invalid_envelope, %{}} =
             Rules.apply(Rules.new(), %{request_id: "bad", operation: :pause, args: %{}, extra: true})

    assert {:error, :unsupported_operation, %{operation: 12}} =
             Rules.apply(Rules.new(), envelope("bad-operation", 12, %{}))

    assert {:error, :unsupported_operation, %{operation: "wat"}} =
             Rules.apply(Rules.new(), envelope("bad-string-operation", "wat", %{}))

    assert {:error, :args_must_be_map, %{}} = Rules.apply(Rules.new(), %{request_id: "bad-args", operation: :pause, args: nil})

    normalized_args = %{
      "expected_revision" => 0,
      "request_id" => "nested",
      "assignment_id" => "assignment",
      "project_id" => "project",
      "project_item_id" => "item",
      "native_project_item_id" => "native-item",
      "native_issue_id" => "native-issue",
      "issue_id" => "issue",
      "issue_node_id" => "issue-node",
      "native_repository_id" => "native-repo",
      "repository_id" => "repo",
      "repository_node_id" => "repo-node",
      "status_field_id" => "field",
      "project_number" => 7,
      "status_options" => %{"READY" => "ready"},
      "repositories" => ["acme/example"],
      "repository" => "acme/example",
      "issue_number" => 12,
      "base_commit" => "base",
      "board_state" => "READY",
      "route" => %{"model" => "gpt-5.6-luna", "effort" => "xhigh"},
      "resources" => ["resource"],
      "dependencies" => [],
      "changes" => %{},
      "disposition" => "waiting",
      "phase" => "READY",
      "provider_state" => "REVIEW",
      "evidence" => ["evidence"],
      "reason" => "reason",
      "disable" => false,
      "owner" => "owner",
      "project" => %{"project_id" => "nested-project"},
      "allowlisted_repositories" => ["acme/example"],
      "model" => "gpt-5.6-luna",
      "effort" => "xhigh",
      "requirements" => %{"body" => true},
      "requirements_fingerprint" => "sha256:body",
      "requirements_revision" => 1,
      "escalation_reason" => "reason",
      "turn_limit" => 5,
      "issue_body" => "private"
    }

    assert {:ok, _, _} = Rules.apply(Rules.new(), envelope("normalized", :pause, normalized_args))
  end

  test "binding, enrollment, revision, dependency, and review error branches are explicit" do
    state = bound_state()

    assert {:ok, _, _} =
             Rules.apply(state, envelope("bind-same", :bind_project, binding_args(1)))

    different_binding = put_in(binding_args(1), [:project, :project_id], "PVT_other")

    assert {:ok, _, _} =
             Rules.apply(state, envelope("bind-other", :bind_project, different_binding))

    invalid_repositories = put_in(binding_args(), [:project, :repositories], [])

    assert {:error, :repository_allowlist_required, %{}} =
             Rules.apply(Rules.new(), envelope("bind-no-repositories", :bind_project, invalid_repositories))

    enrolled = enrolled_state("issue-1")

    conflict_binding = put_in(binding_args(2), [:project, :project_id], "PVT_other")

    assert {:error, :binding_in_use, %{assignment_id: "issue-1"}} =
             Rules.apply(enrolled, envelope("bind-conflict", :bind_project, conflict_binding))

    cancelled = put_in(enrolled, [:assignments, "issue-1", :phase], :cancelled)

    cancel_terminal = %{assignment_id: "issue-1", expected_revision: 1, reason: "done"}

    assert {:error, :already_terminal, %{phase: :cancelled}} =
             Rules.apply(cancelled, envelope("cancel-terminal", :cancel, cancel_terminal))

    assert {:error, :project_not_bound, %{}} =
             Rules.apply(Rules.new(), envelope("enroll-unbound", :enroll, enrollment_args("issue-1", 0)))

    malformed_binding = Rules.new(binding: %{})

    assert {:error, :project_not_bound, %{}} =
             Rules.apply(malformed_binding, envelope("enroll-malformed-binding", :enroll, enrollment_args("issue-1", 0)))

    invalid_number = put_in(binding_args(), [:project, :project_number], "bad")

    assert {:error, :invalid_argument, %{argument: :project_number}} =
             Rules.apply(Rules.new(), envelope("bind-invalid-number", :bind_project, invalid_number))

    missing_revision = %{assignment_id: "missing", expected_revision: 0, changes: %{}}

    assert {:error, :assignment_not_found, %{assignment_id: "missing"}} =
             Rules.apply(enrolled, envelope("revise-missing", :revise, missing_revision))

    waiting =
      enrolled
      |> put_in([:assignments, "issue-1", :phase], :waiting)
      |> put_in([:assignments, "issue-1", :board_state], :waiting)
      |> put_in([:assignments, "issue-1", :revision], 2)

    base_revision = %{assignment_id: "issue-1", expected_revision: 2}

    assert {:error, :changes_must_be_map, %{}} =
             Rules.apply(waiting, envelope("revise-nonmap", :revise, Map.merge(base_revision, %{changes: "bad"})))

    assert {:error, :invalid_argument, %{argument: :requirements}} =
             Rules.apply(waiting, envelope("revise-bad-requirements", :revise, Map.merge(base_revision, %{changes: %{requirements: "bad"}})))

    assert {:error, :invalid_argument, %{argument: :resources}} =
             Rules.apply(waiting, envelope("revise-bad-resources", :revise, Map.merge(base_revision, %{changes: %{resources: :bad}})))

    assert {:error, :invalid_argument, %{argument: :requirements_revision}} =
             Rules.apply(waiting, envelope("revise-bad-revision", :revise, Map.merge(base_revision, %{changes: %{requirements_revision: "bad"}})))

    assert {:ok, _, _} = Rules.apply(waiting, envelope("revise-base-commit", :revise, Map.merge(base_revision, %{changes: %{base_commit: "new-base"}})))

    assert {:error, :invalid_argument, %{argument: :requirements_revision}} =
             Rules.apply(state, envelope("enroll-bad-requirements-revision", :enroll, enrollment_args("bad-revision", 1) |> Map.put(:requirements_revision, -1)))

    active = put_in(enrolled, [:assignments, "issue-1", :phase], :active)
    active = put_in(active, [:assignments, "issue-1", :board_state], :active)

    assert {:ok, interrupted, interrupt_response} =
             Rules.apply(active, envelope("interrupt-active", :interrupt, %{assignment_id: "issue-1", expected_revision: 1, reason: "pause"}))

    assert interrupted.assignments["issue-1"].phase == :waiting
    assert interrupt_response.phase == :waiting

    assert {:ok, cancelled_state, cancel_response} =
             Rules.apply(enrolled, envelope("cancel-ready", :cancel, %{assignment_id: "issue-1", expected_revision: 1, reason: "stop"}))

    assert cancelled_state.assignments["issue-1"].phase == :cancelled
    assert cancel_response.phase == :cancelled

    dependent = enrolled_state("dependent", dependencies: ["missing"])

    dependent =
      dependent
      |> put_in([:assignments, "dependent", :phase], :review)
      |> put_in([:assignments, "dependent", :board_state], :review)
      |> put_in([:assignments, "dependent", :revision], 2)

    review_args = %{assignment_id: "dependent", expected_revision: 2, disposition: "accepted", evidence: ["proof"]}
    proof = %{provider_state: :review, reconciled: true, external_effects: %{status: :ok, issue_close: :ok}}
    assert {:error, :dependency_not_accepted, %{dependencies: ["missing"]}} = Rules.apply(dependent, envelope("dependent-review", :review, review_args), proof)

    assert {:error, :external_effects_unreconciled, %{}} =
             Rules.apply(dependent |> put_in([:assignments, "dependent", :dependencies], []), envelope("review-no-effects", :review, review_args), %{provider_state: :review})

    assert {:error, :evidence_required, %{}} =
             Rules.apply(dependent |> put_in([:assignments, "dependent", :dependencies], []), envelope("review-no-evidence", :review, Map.put(review_args, :evidence, [])), proof)

    assert {:error, :invalid_disposition, %{disposition: :unknown}} = Rules.apply(dependent, envelope("review-invalid", :review, Map.merge(review_args, %{disposition: "mystery", reason: "bad"})))

    assert {:error, :invalid_disposition, %{disposition: :unknown}} =
             Rules.prepare_review(dependent, envelope("review-invalid-prepare", :review, Map.merge(review_args, %{disposition: "mystery", reason: "bad"})))

    review_state = put_in(dependent, [:assignments, "dependent", :dependencies], [])
    review_state = put_in(review_state, [:assignments, "dependent", :revision], 2)
    review_request = envelope("review-prepare", :review, Map.merge(review_args, %{disposition: "accepted"}))
    assert {:ok, _review_intent} = Rules.prepare_review(review_state, review_request)

    duplicate_review =
      put_in(review_state, [:requests, "review-prepare"], %{canonical: Rules.canonical_input(review_request), response: %{}})

    assert {:duplicate, %{}} = Rules.prepare_review(duplicate_review, review_request)

    conflict_review = put_in(review_state, [:requests, "review-prepare"], %{canonical: <<0>>, response: %{}})
    assert {:error, :request_id_conflict, %{request_id: "review-prepare"}} = Rules.prepare_review(conflict_review, review_request)

    assert {:error, :invalid_envelope, %{}} = Rules.prepare_review(Rules.new(), %{request_id: "bad", operation: :review, args: %{}, extra: true})
  end

  test "binding and enrollment accept list/native identity inputs and enforce caps" do
    list_binding = put_in(binding_args(), [:project, :status_options], [%{name: "READY", id: "ready"}])
    assert {:ok, list_bound, _} = Rules.apply(Rules.new(), envelope("bind-list", :bind_project, list_binding))

    native_args = enrollment_args("native-issue", 1) |> Map.merge(%{issue_id: "node-issue", repository_id: "node-repo", turn_limit: 99})
    assert {:ok, native_state, _} = Rules.apply(list_bound, envelope("enroll-native", :enroll, native_args))
    assert native_state.assignments["native-issue"].underlying_issue_id == "node-issue"
    assert native_state.assignments["native-issue"].turn_limit == 20

    alias_args = enrollment_args("alias-issue", 2) |> Map.merge(%{issue_node_id: "node-issue-2", repository_node_id: "node-repo-2", issue_number: 98, resources: ["repo:alias"]})
    assert {:ok, alias_state, _} = Rules.apply(native_state, envelope("enroll-native-aliases", :enroll, alias_args))
    assert alias_state.assignments["alias-issue"].native_issue_id == "node-issue-2"
    assert alias_state.assignments["alias-issue"].native_repository_id == "node-repo-2"

    duplicate_native = enrollment_args("native-issue-2", 2) |> Map.merge(%{native_issue_id: "node-issue", native_repository_id: "node-repo", issue_number: 99})

    assert {:error, :duplicate_underlying_identity, %{assignment_id: "native-issue"}} =
             Rules.apply(native_state, envelope("enroll-native-duplicate", :enroll, duplicate_native))

    invalid_list_binding = put_in(binding_args(), [:project, :status_options], [1])
    assert {:error, :status_options_required, %{}} = Rules.apply(Rules.new(), envelope("bind-invalid-list", :bind_project, invalid_list_binding))

    invalid_project = %{project: :bad, expected_revision: 0}
    assert {:error, :invalid_argument, %{argument: :project_id}} = Rules.apply(Rules.new(), envelope("bind-invalid-project", :bind_project, invalid_project))

    invalid_enroll = enrollment_args("bad-resources", 1) |> Map.put(:resources, :bad)
    assert {:error, :invalid_argument, %{argument: :resources}} = Rules.apply(list_bound, envelope("enroll-invalid-resources", :enroll, invalid_enroll))

    invalid_phase = enrollment_args("bad-phase", 1) |> Map.put(:board_state, "ACTIVE")
    assert {:error, :invalid_phase, %{}} = Rules.apply(list_bound, envelope("enroll-invalid-phase", :enroll, invalid_phase))

    assert {:ok, _string_operation_state, _} = Rules.apply(Rules.new(), envelope("string-operation", "pause", %{"expected_revision" => 0}))
  end

  test "request history remains bounded after many valid operations" do
    state =
      Enum.reduce(1..101, Rules.new(), fn index, state ->
        assert {:ok, next_state, _response} = Rules.apply(state, envelope("pause-#{index}", :pause, %{expected_revision: index - 1}))
        next_state
      end)

    assert map_size(state.requests) == 100
    assert state.control_revision == 101
    assert Rules.snapshot(state).cursor == 101
  end
end
