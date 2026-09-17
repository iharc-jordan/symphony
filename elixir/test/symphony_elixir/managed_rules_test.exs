defmodule SymphonyElixir.ManagedRulesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.Rules

  @operator %{principal_id: "operator", role: :operator, project_scope: :all}
  @pm %{principal_id: "pm", role: :pm, project_scope: :all}

  defp envelope(id, operation, args) do
    %{request_id: id, operation: operation, args: enrich_args(operation, args)}
  end

  defp enrich_args(operation, args)
       when operation in [:revise, :interrupt, :cancel, :review] and is_map(args) do
    args
    |> Map.put_new(:project_id, "PVT_kwDO")
    |> Map.put_new(:expected_ownership_revision, 1)
  end

  defp enrich_args(operation, args) when operation in [:pause, :resume] do
    enrich_assignment_scope(args)
  end

  defp enrich_args(_operation, args), do: args

  defp enrich_assignment_scope(args) when is_map(args) do
    if Map.has_key?(args, :assignments) or Map.has_key?(args, "assignments") do
      args
      |> Map.put_new(:project_id, "PVT_kwDO")
      |> Map.update!(:assignments, &enrich_assignment_fences/1)
    else
      args
    end
  end

  defp enrich_assignment_scope(args), do: args

  defp enrich_assignment_fences(assignments) do
    Enum.map(assignments, &enrich_assignment_fence/1)
  end

  defp enrich_assignment_fence(fence) do
    fence
    |> Map.put_new(:expected_revision, 1)
    |> Map.put_new(:expected_ownership_revision, 1)
  end

  defp principal_for(:bind_project, _args), do: @operator
  defp principal_for(:operator_takeover, _args), do: @operator
  defp principal_for(:register_pm, _args), do: @pm

  defp principal_for(:pause, args) when is_map(args) do
    if Map.has_key?(args, :assignments) or Map.has_key?(args, "assignments"), do: @pm, else: @operator
  end

  defp principal_for(:resume, args) when is_map(args) do
    if Map.has_key?(args, :assignments) or Map.has_key?(args, "assignments"), do: @pm, else: @operator
  end

  defp principal_for("pause", _args), do: @operator
  defp principal_for("resume", _args), do: @operator
  defp principal_for(_operation, _args), do: @pm

  defp apply_request(state, request, context \\ %{}) do
    operation = Map.get(request, :operation, Map.get(request, "operation"))
    args = Map.get(request, :args, Map.get(request, "args", %{}))
    context = Map.put_new(context, :principal, principal_for(operation, args))
    Rules.apply(state, request, context)
  end

  defp prepare_request(state, request, context \\ %{}) do
    operation = Map.get(request, :operation, Map.get(request, "operation"))
    args = Map.get(request, :args, Map.get(request, "args", %{}))
    context = Map.put_new(context, :principal, principal_for(operation, args))
    Rules.prepare_review(state, request, context)
  end

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
      project_id: "PVT_kwDO",
      resources:
        Keyword.get(opts, :resources, [
          %{kind: :repository, authority: "github", identity: "acme/example", access: :write}
        ]),
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
      apply_request(Rules.new(), envelope("bind-1", :bind_project, binding_args()))

    state
  end

  defp enrolled_state(id, opts \\ []) do
    state = bound_state()

    {:ok, state, _response} =
      apply_request(state, envelope("enroll-" <> id, :enroll, enrollment_args(id, 1, opts)))

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
    evidence = Enum.map(1..21, &"failed acceptance check #{&1}")

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
        reason: "needs changes",
        evidence: evidence
      })

    assert {:ok, intent} = prepare_request(state, rework)
    assert intent.disposition == :rework
    refute intent.requires_effects

    invalid_evidence = put_in(rework, [:args, :evidence], "A list is required")

    assert {:error, :invalid_argument, %{argument: :evidence}} =
             apply_request(state, invalid_evidence)

    assert {:ok, reworked, rework_response} = apply_request(state, rework)
    assert rework_response.phase == :ready
    assert reworked.assignments["issue-1"].phase == :ready
    assert reworked.assignments["issue-1"].board_state == :ready

    assert reworked.assignments["issue-1"].review_feedback == %{
             reason: "needs changes",
             evidence: evidence
           }

    blocked =
      envelope("review-blocked", :review, %{
        assignment_id: "issue-1",
        expected_revision: 2,
        disposition: "blocked",
        reason: "waiting on dependency"
      })

    assert {:ok, blocked_state, blocked_response} = apply_request(state, blocked)
    assert blocked_response.phase == :waiting
    assert blocked_state.assignments["issue-1"].phase == :waiting
    assert blocked_state.assignments["issue-1"].board_state == :waiting
  end

  test "request ids replay the recorded response and reject changed input" do
    state = bound_state()
    request = envelope("same-id", :enroll, enrollment_args("issue-1", 1))

    assert {:ok, next_state, response} = apply_request(state, request)
    assert {:duplicate, duplicate_response} = apply_request(next_state, request)
    assert Map.put(response, :duplicate, true) == Map.put(duplicate_response, :duplicate, true)

    changed = envelope("same-id", :enroll, enrollment_args("issue-2", 2))
    assert {:error, :request_id_conflict, %{request_id: "same-id"}} = apply_request(next_state, changed)
  end

  test "enrollment enforces repository, identity, and exclusive resources" do
    state = enrolled_state("issue-1")

    assert {:error, :duplicate_underlying_identity, %{assignment_id: "issue-1"}} =
             apply_request(state, envelope("enroll-2", :enroll, enrollment_args("issue-2", 2)))

    assert {:error, :resource_conflict, %{assignment_id: "issue-1"}} =
             apply_request(
               state,
               envelope("enroll-3", :enroll, enrollment_args("issue-3", 2, issue_number: 13))
             )
  end

  test "full issue requirements are never persisted without a material fingerprint" do
    state = bound_state()

    assert {:error, :requirements_fingerprint_required, %{}} =
             apply_request(
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

    assert {:ok, next_state, _} = apply_request(state, envelope("enroll-with-fingerprint", :enroll, args))
    assignment = next_state.assignments["issue-1"]
    refute Map.has_key?(assignment, :requirements)
    assert assignment.requirements_fingerprint == "sha256:body"
    assert assignment.requirements_revision == 4

    changed_body = put_in(args, [:requirements, "secret"], "different")

    assert Rules.canonical_input(%{request_id: "r", operation: :enroll, args: args}) ==
             Rules.canonical_input(%{request_id: "r", operation: :enroll, args: changed_body})
  end

  test "enrollment keeps trusted source title and URL metadata outside the request" do
    state = bound_state()
    request = envelope("enroll-source-metadata", :enroll, enrollment_args("issue-1", 1))
    canonical = Rules.canonical_input(request)

    context = %{
      source_identity: %{
        title: "Authoritative title",
        issue_url: "https://github.com/acme/example/issues/12"
      }
    }

    assert {:ok, enrolled, _response} = apply_request(state, request, context)
    assignment = enrolled.assignments["issue-1"]
    assert assignment.title == "Authoritative title"
    assert assignment.issue_url == "https://github.com/acme/example/issues/12"
    assert Rules.canonical_input(request) == canonical
  end

  test "review acceptance requires provider and reconciled effect facts from service context" do
    state =
      enrolled_state("issue-1")
      |> put_in([:assignments, "issue-1", :phase], :review)
      |> put_in([:assignments, "issue-1", :board_state], :review)
      |> put_in([:assignments, "issue-1", :revision], 2)

    args = %{assignment_id: "issue-1", expected_revision: 2, disposition: "accepted", evidence: ["test log"]}

    assert {:error, :provider_state_not_review, %{}} =
             apply_request(state, envelope("review-no-proof", :review, Map.put(args, :provider_state, "review")))

    context = %{
      provider_state: :review,
      reconciled: true,
      external_effects: %{status: :ok, issue_close: :ok}
    }

    assert {:ok, accepted, response} = apply_request(state, envelope("review-ok", :review, args), context)
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

    assert {:error, :active_assignment_stop_required, %{}} = apply_request(state, request)

    assert {:ok, revised, _} =
             apply_request(state, request, %{stop_reconciled: true})

    assert revised.assignments["issue-1"].phase == :ready
    assert revised.assignments["issue-1"].revision == 3
  end

  test "service stop reconciliation clears interrupt and cancel stop_pending" do
    for operation <- [:interrupt, :cancel] do
      state =
        enrolled_state("issue-1")
        |> put_in([:assignments, "issue-1", :phase], :active)
        |> put_in([:assignments, "issue-1", :board_state], :active)

      request =
        envelope("stop-#{operation}", operation, %{
          assignment_id: "issue-1",
          expected_revision: 1,
          reason: "operator stop"
        })

      assert {:ok, pending, _response} = apply_request(state, request)
      assert pending.assignments["issue-1"].stop_pending == true

      assert {:ok, reconciled, _response} =
               apply_request(state, request, %{stop_reconciled: true})

      assert reconciled.assignments["issue-1"].stop_pending == false
    end
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
             apply_request(state, request)

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

    assert {:ok, revised, _response} = apply_request(state, body_request)
    refute Map.has_key?(revised.assignments["issue-1"], :requirements)
    assert revised.assignments["issue-1"].requirements_fingerprint == "sha256:body"
  end

  test "stop-pending assignments continue to hold resources" do
    state =
      enrolled_state("issue-1")
      |> put_in([:assignments, "issue-1", :phase], :waiting)
      |> put_in([:assignments, "issue-1", :stop_pending], true)

    assert {:error, :resource_conflict, %{assignment_id: "issue-1"}} =
             apply_request(
               state,
               envelope("enroll-2", :enroll, enrollment_args("issue-2", 2, issue_number: 13))
             )
  end

  test "public rule APIs reject malformed requests and cover lifecycle guards" do
    assert Rules.version() == 2
    assert :bind_project in Rules.allowed_operations()
    assert Rules.phase(123) == :unknown
    assert Rules.validate_route(%{model: "gpt-5.6-luna", effort: "xhigh"}) == :ok
    assert {:error, :invalid_route, %{}} = Rules.validate_route(:bad, nil)

    assert {:error, :invalid_route, %{model: "wat", effort: "max"}} =
             Rules.validate_route(%{model: "wat", effort: "max"})

    assert {:error, :route_escalation_reason_required, %{}} =
             Rules.validate_route(%{model: "gpt-5.6-terra", effort: "max"})

    for effort <- ["xhigh", "max"] do
      route = %{model: "gpt-5.6-sol", effort: effort}
      assert :ok = Rules.validate_route(route, "Connected runtime fencing requires Sol")

      assert {:error, :route_escalation_reason_required, %{model: "gpt-5.6-sol", effort: ^effort}} =
               Rules.validate_route(route)
    end

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
             apply_request(Rules.new(), %{request_id: "bad", operation: :pause, args: %{}, extra: true})

    assert {:error, :unsupported_operation, %{operation: 12}} =
             apply_request(Rules.new(), envelope("bad-operation", 12, %{}))

    assert {:error, :unsupported_operation, %{operation: "wat"}} =
             apply_request(Rules.new(), envelope("bad-string-operation", "wat", %{}))

    assert {:error, :args_must_be_map, %{}} = apply_request(Rules.new(), %{request_id: "bad-args", operation: :pause, args: nil})

    normalized_args = %{
      "expected_revision" => 0,
      "request_id" => "nested",
      "assignment_id" => "assignment",
      "project_id" => "project",
      "project_item_id" => "item",
      "native_issue_id" => "native-issue",
      "native_repository_id" => "native-repo",
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

    assert {:ok, _, _} = apply_request(Rules.new(), envelope("normalized", :pause, normalized_args))
  end

  test "binding, enrollment, revision, dependency, and review error branches are explicit" do
    state = bound_state()

    assert {:ok, _, _} =
             apply_request(state, envelope("bind-same", :bind_project, binding_args(1)))

    different_binding = put_in(binding_args(1), [:project, :project_id], "PVT_other")

    assert {:ok, _, _} =
             apply_request(state, envelope("bind-other", :bind_project, different_binding))

    invalid_repositories = put_in(binding_args(), [:project, :repositories], [])

    assert {:error, :repository_allowlist_required, %{}} =
             apply_request(Rules.new(), envelope("bind-no-repositories", :bind_project, invalid_repositories))

    enrolled = enrolled_state("issue-1")

    other_project_binding = put_in(binding_args(2), [:project, :project_id], "PVT_other")

    assert {:ok, expanded, _} =
             apply_request(enrolled, envelope("bind-other-project", :bind_project, other_project_binding))

    assert expanded.projects["PVT_other"].project_id == "PVT_other"

    cancelled = put_in(enrolled, [:assignments, "issue-1", :phase], :cancelled)

    cancel_terminal = %{assignment_id: "issue-1", expected_revision: 1, reason: "done"}

    assert {:error, :already_terminal, %{phase: :cancelled}} =
             apply_request(cancelled, envelope("cancel-terminal", :cancel, cancel_terminal))

    assert {:error, :project_not_bound, %{}} =
             apply_request(Rules.new(), envelope("enroll-unbound", :enroll, enrollment_args("issue-1", 0)))

    malformed_binding = Rules.new(projects: %{"PVT_kwDO" => %{}})

    assert {:error, :project_not_bound, %{}} =
             apply_request(malformed_binding, envelope("enroll-malformed-binding", :enroll, enrollment_args("issue-1", 0)))

    invalid_number = put_in(binding_args(), [:project, :project_number], "bad")

    assert {:error, :invalid_argument, %{argument: :project_number}} =
             apply_request(Rules.new(), envelope("bind-invalid-number", :bind_project, invalid_number))

    missing_revision = %{assignment_id: "missing", expected_revision: 0, changes: %{}}

    assert {:error, :assignment_not_found, %{assignment_id: "missing"}} =
             apply_request(enrolled, envelope("revise-missing", :revise, missing_revision))

    waiting =
      enrolled
      |> put_in([:assignments, "issue-1", :phase], :waiting)
      |> put_in([:assignments, "issue-1", :board_state], :waiting)
      |> put_in([:assignments, "issue-1", :revision], 2)

    base_revision = %{assignment_id: "issue-1", expected_revision: 2}

    assert {:error, :changes_must_be_map, %{}} =
             apply_request(waiting, envelope("revise-nonmap", :revise, Map.merge(base_revision, %{changes: "bad"})))

    assert {:error, :invalid_argument, %{argument: :requirements}} =
             apply_request(waiting, envelope("revise-bad-requirements", :revise, Map.merge(base_revision, %{changes: %{requirements: "bad"}})))

    assert {:error, :invalid_argument, %{argument: :resources}} =
             apply_request(waiting, envelope("revise-bad-resources", :revise, Map.merge(base_revision, %{changes: %{resources: :bad}})))

    assert {:error, :invalid_argument, %{argument: :requirements_revision}} =
             apply_request(waiting, envelope("revise-bad-revision", :revise, Map.merge(base_revision, %{changes: %{requirements_revision: "bad"}})))

    assert {:ok, _, _} = apply_request(waiting, envelope("revise-base-commit", :revise, Map.merge(base_revision, %{changes: %{base_commit: "new-base"}})))

    assert {:error, :invalid_argument, %{argument: :requirements_revision}} =
             apply_request(state, envelope("enroll-bad-requirements-revision", :enroll, enrollment_args("bad-revision", 1) |> Map.put(:requirements_revision, -1)))

    active = put_in(enrolled, [:assignments, "issue-1", :phase], :active)
    active = put_in(active, [:assignments, "issue-1", :board_state], :active)

    assert {:ok, interrupted, interrupt_response} =
             apply_request(active, envelope("interrupt-active", :interrupt, %{assignment_id: "issue-1", expected_revision: 1, reason: "pause"}))

    assert interrupted.assignments["issue-1"].phase == :waiting
    assert interrupt_response.phase == :waiting

    assert {:ok, cancelled_state, cancel_response} =
             apply_request(enrolled, envelope("cancel-ready", :cancel, %{assignment_id: "issue-1", expected_revision: 1, reason: "stop"}))

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

    assert {:error, :dependency_not_accepted, %{dependencies: ["missing"]}} =
             apply_request(dependent, envelope("dependent-review", :review, review_args), proof)

    assert {:error, :external_effects_unreconciled, %{}} =
             apply_request(
               dependent |> put_in([:assignments, "dependent", :dependencies], []),
               envelope("review-no-effects", :review, review_args),
               %{provider_state: :review}
             )

    assert {:error, :evidence_required, %{}} =
             apply_request(
               dependent |> put_in([:assignments, "dependent", :dependencies], []),
               envelope("review-no-evidence", :review, Map.put(review_args, :evidence, [])),
               proof
             )

    invalid_review =
      envelope(
        "review-invalid",
        :review,
        Map.merge(review_args, %{disposition: "mystery", reason: "bad"})
      )

    assert {:error, :invalid_disposition, %{disposition: :unknown}} =
             apply_request(dependent, invalid_review)

    invalid_prepare =
      envelope(
        "review-invalid-prepare",
        :review,
        Map.merge(review_args, %{disposition: "mystery", reason: "bad"})
      )

    assert {:error, :invalid_disposition, %{disposition: :unknown}} =
             prepare_request(dependent, invalid_prepare)

    review_state = put_in(dependent, [:assignments, "dependent", :dependencies], [])
    review_state = put_in(review_state, [:assignments, "dependent", :revision], 2)
    review_request = envelope("review-prepare", :review, Map.merge(review_args, %{disposition: "accepted"}))
    assert {:ok, _review_intent} = prepare_request(review_state, review_request)

    duplicate_review =
      put_in(
        review_state,
        [:requests, "review-prepare"],
        %{
          canonical: Rules.canonical_input(review_request),
          response: %{},
          principal_id: @pm.principal_id
        }
      )

    assert {:duplicate, %{}} = prepare_request(duplicate_review, review_request)

    conflict_review = put_in(review_state, [:requests, "review-prepare"], %{canonical: <<0>>, response: %{}})

    assert {:error, :request_id_conflict, %{request_id: "review-prepare"}} =
             prepare_request(conflict_review, review_request)

    assert {:error, :invalid_envelope, %{}} = prepare_request(Rules.new(), %{request_id: "bad", operation: :review, args: %{}, extra: true})
  end

  test "binding and enrollment accept canonical native identity inputs and enforce caps" do
    list_binding = put_in(binding_args(), [:project, :status_options], [%{name: "READY", id: "ready"}])
    assert {:ok, list_bound, _} = apply_request(Rules.new(), envelope("bind-list", :bind_project, list_binding))

    native_args =
      enrollment_args("native-issue", 1)
      |> Map.merge(%{native_issue_id: "node-issue", native_repository_id: "node-repo", turn_limit: 20})

    assert {:ok, native_state, _} = apply_request(list_bound, envelope("enroll-native", :enroll, native_args))
    assert native_state.assignments["native-issue"].underlying_issue_id == "node-issue"
    assert native_state.assignments["native-issue"].turn_limit == 20

    oversized = enrollment_args("oversized-limit", 2, issue_number: 13) |> Map.put(:turn_limit, 21)

    assert {:error, :invalid_argument, %{argument: :turn_limit, minimum: 1, maximum: 20}} =
             apply_request(native_state, envelope("enroll-oversized-limit", :enroll, oversized))

    duplicate_native =
      enrollment_args("native-issue-2", 2)
      |> Map.merge(%{
        native_issue_id: "node-issue",
        native_repository_id: "node-repo",
        issue_number: 99
      })

    assert {:error, :duplicate_underlying_identity, %{assignment_id: "native-issue"}} =
             apply_request(native_state, envelope("enroll-native-duplicate", :enroll, duplicate_native))

    obsolete_alias = enrollment_args("obsolete-native-alias", 2) |> Map.put(:issue_node_id, "node-issue-2")

    assert {:error, :invalid_argument, %{argument: :issue_node_id}} =
             apply_request(native_state, envelope("enroll-obsolete-native-alias", :enroll, obsolete_alias))

    invalid_list_binding = put_in(binding_args(), [:project, :status_options], [1])

    assert {:error, :status_options_required, %{}} =
             apply_request(Rules.new(), envelope("bind-invalid-list", :bind_project, invalid_list_binding))

    invalid_project = %{project: %{project_id: 12}, expected_revision: 0}

    assert {:error, :invalid_argument, %{argument: :project_id}} =
             apply_request(Rules.new(), envelope("bind-invalid-project", :bind_project, invalid_project))

    invalid_enroll = enrollment_args("bad-resources", 1) |> Map.put(:resources, :bad)
    invalid_resource_request = envelope("enroll-invalid-resources", :enroll, invalid_enroll)

    assert {:error, :invalid_argument, %{argument: :resources}} =
             apply_request(list_bound, invalid_resource_request)

    invalid_phase = enrollment_args("bad-phase", 1) |> Map.put(:board_state, "ACTIVE")

    assert {:error, :invalid_phase, %{}} =
             apply_request(list_bound, envelope("enroll-invalid-phase", :enroll, invalid_phase))

    assert {:ok, _string_operation_state, _} = apply_request(Rules.new(), envelope("string-operation", "pause", %{"expected_revision" => 0}))
  end

  test "material revisions clear old review feedback and route changes reset the session" do
    state = enrolled_state("issue-1")

    state =
      update_in(state, [:assignments, "issue-1"], fn assignment ->
        Map.merge(assignment, %{
          thread_id: "old-thread",
          session_id: "old-thread",
          turn_id: "old-turn",
          model: "gpt-5.6-luna",
          effort: "xhigh",
          metadata: %{process: "stopped"},
          resume_ready: true,
          workspace: "/assigned/checkout",
          turns_reserved: 7,
          retry_count: 1,
          review_feedback: %{reason: "Previous revision finding", evidence: ["Previous revision evidence"]}
        })
      end)

    for route <- [%{model: "gpt-5.6-luna", effort: "max"}, %{model: "gpt-5.6-terra", effort: "xhigh"}] do
      args = %{assignment_id: "issue-1", expected_revision: 1, changes: %{route: route, escalation_reason: "Diagnosis requires additional reasoning"}}
      assert {:ok, revised, _} = apply_request(state, envelope("change-route", :revise, args), %{stop_reconciled: true})
      assignment = revised.assignments["issue-1"]
      assert assignment.route == route
      assert assignment.revision == 2
      refute assignment.resume_ready
      refute Map.has_key?(assignment, :thread_id)
      refute Map.has_key?(assignment, :metadata)
      assert assignment.workspace == "/assigned/checkout"
      assert assignment.turns_reserved == 7
      assert assignment.retry_count == 0
      refute Map.has_key?(assignment, :review_feedback)
    end

    same_route = %{assignment_id: "issue-1", expected_revision: 1, changes: %{route: %{model: "gpt-5.6-luna", effort: "xhigh"}}}
    assert {:ok, same, _} = apply_request(state, envelope("same-route", :revise, same_route), %{stop_reconciled: true})
    assert same.assignments["issue-1"].thread_id == "old-thread"
    assert same.assignments["issue-1"].resume_ready
    refute Map.has_key?(same.assignments["issue-1"], :review_feedback)
  end

  test "revision extends the absolute lifetime turn limit only with a non-empty reason" do
    state =
      enrolled_state("issue-1")
      |> put_in([:assignments, "issue-1", :turns_reserved], 17)

    base = %{assignment_id: "issue-1", expected_revision: 1}

    assert {:error, :turn_limit_reason_required, %{}} =
             apply_request(
               state,
               envelope("limit-no-reason", :revise, Map.put(base, :changes, %{turn_limit: 30}))
             )

    assert {:error, :turn_limit_required, %{}} =
             apply_request(
               state,
               envelope(
                 "limit-reason-only",
                 :revise,
                 Map.put(base, :changes, %{turn_limit_reason: "More investigation"})
               )
             )

    assert {:error, :turn_limit_must_increase, %{existing: 20, requested: 20}} =
             apply_request(
               state,
               envelope(
                 "limit-not-increased",
                 :revise,
                 Map.put(base, :changes, %{turn_limit: 20, turn_limit_reason: "More investigation"})
               )
             )

    assert {:error, :invalid_argument, %{argument: :turn_limit, minimum: 1, maximum: 100}} =
             apply_request(
               state,
               envelope(
                 "limit-too-large",
                 :revise,
                 Map.put(base, :changes, %{turn_limit: 101, turn_limit_reason: "More investigation"})
               )
             )

    changes = %{turn_limit: 30, turn_limit_reason: "Complete the connected recovery checks"}

    assert {:ok, revised, response} =
             apply_request(
               state,
               envelope("limit-extended", :revise, Map.put(base, :changes, changes))
             )

    assignment = revised.assignments["issue-1"]
    assert assignment.turn_limit == 30
    assert assignment.turn_limit_reason == changes.turn_limit_reason
    assert assignment.turns_reserved == 17
    assert response.turn_limit == 30
    assert response.turn_limit_reason == changes.turn_limit_reason
    assert hd(revised.events).turn_limit == 30
    assert hd(revised.events).turn_limit_reason == changes.turn_limit_reason
  end

  test "accepted review may use only the current fenced context-needed WAITING report" do
    assignment =
      enrolled_state("issue-1").assignments["issue-1"]
      |> Map.merge(%{
        phase: :waiting,
        board_state: :waiting,
        revision: 2,
        generation: 1,
        attempt_id: "attempt-1",
        worker_active: false,
        last_report: %{
          kind: "context_needed",
          attempt_id: "attempt-1",
          report_id: "context-1",
          summary: "Need PM evidence",
          evidence: []
        }
      })

    state = put_in(enrolled_state("issue-1"), [:assignments, "issue-1"], assignment)
    args = %{assignment_id: "issue-1", expected_revision: 2, disposition: "accepted", evidence: ["PM verified the requested context"]}

    proof = %{
      managed_process_state: :inactive_reconciled,
      provider_state: :review,
      reconciled: true,
      external_effects: %{status: :ok, issue_close: :ok}
    }

    assert {:ok, accepted, response} =
             apply_request(state, envelope("accept-context-needed", :review, args), proof)

    assert accepted.assignments["issue-1"].phase == :accepted
    assert response.issue_close == :ok

    assert {:ok, _intent} =
             prepare_request(
               state,
               envelope("accept-string-process-state", :review, args),
               %{"managed_process_state" => "inactive_reconciled"}
             )

    assert {:error, :managed_process_not_inactive_reconciled, %{process_state: :active}} =
             prepare_request(
               state,
               envelope("accept-active", :review, args),
               %{managed_process_state: :active}
             )

    assert {:error, :evidence_required, %{}} =
             prepare_request(
               state,
               envelope("accept-missing-evidence", :review, %{args | evidence: []}),
               %{managed_process_state: :inactive_reconciled}
             )

    wrong_report = put_in(state, [:assignments, "issue-1", :last_report, :kind], "result")

    assert {:error, :context_needed_report_required, %{}} =
             prepare_request(
               wrong_report,
               envelope("accept-wrong-report-kind", :review, args),
               %{managed_process_state: :inactive_reconciled}
             )

    ready_state =
      state
      |> put_in([:assignments, "issue-1", :phase], :ready)
      |> put_in([:assignments, "issue-1", :board_state], :ready)

    assert {:error, :invalid_phase, %{expected: :review, actual: :ready}} =
             prepare_request(
               ready_state,
               envelope("accept-ready-assignment", :review, args),
               %{managed_process_state: :inactive_reconciled}
             )

    stale_report = put_in(state, [:assignments, "issue-1", :last_report, :attempt_id], "attempt-0")

    assert {:error, :stale_context_needed_report, %{}} =
             prepare_request(
               stale_report,
               envelope("accept-stale-report", :review, args),
               %{managed_process_state: :inactive_reconciled}
             )

    assert {:error, :stale_revision, %{expected: 1, actual: 2}} =
             prepare_request(
               state,
               envelope("accept-stale-revision", :review, %{args | expected_revision: 1}),
               %{managed_process_state: :inactive_reconciled}
             )

    wrong_owner = %{principal_id: "different-pm", role: :pm, project_scope: :all}

    assert {:error, :ownership_conflict, _details} =
             prepare_request(
               state,
               envelope("accept-wrong-owner", :review, args),
               %{principal: wrong_owner, managed_process_state: :inactive_reconciled}
             )
  end

  test "strict authorization and defensive lifecycle branches are explicit" do
    state = bound_state()
    bind_request = envelope("auth-bind", :bind_project, binding_args())

    assert {:error, :principal_required, %{}} = Rules.authorize(state, bind_request, nil)
    assert {:error, :principal_required, %{}} = Rules.apply(state, bind_request)
    assert {:error, :principal_required, %{}} = Rules.prepare_review(state, bind_request)
    assert {:error, :principal_required, %{}} = Rules.apply(state, bind_request, %{})
    assert :ok = Rules.authorize(state, bind_request, %{principal_context: @operator})
    assert :ok = Rules.authorize(state, bind_request, %{"principal_context" => @operator})
    assert {:error, :principal_required, %{}} = Rules.authorize(state, bind_request, %{principal_context: %{}})

    assert {:error, :operator_required, %{operation: :bind_project}} =
             Rules.apply(Rules.new(), bind_request, %{principal: @pm})

    assert {:error, :operator_required, %{operation: :operator_takeover}} =
             Rules.apply(
               state,
               envelope("takeover-denied", :operator_takeover, %{}),
               %{principal: @pm}
             )

    assert {:error, :pm_required, %{}} =
             Rules.apply(
               state,
               envelope("register-denied", :register_pm, %{}),
               %{principal: @operator}
             )

    assert {:error, :pm_required, %{}} =
             Rules.apply(
               state,
               envelope("enroll-denied", :enroll, enrollment_args("denied", 1)),
               %{principal: @operator}
             )

    enrolled = enrolled_state("issue-1")
    claim_args = %{project_id: "PVT_kwDO", assignment_id: "issue-1", expected_revision: 1, expected_ownership_revision: 1}

    assert {:error, :operator_takeover_required, %{assignment_id: "issue-1"}} =
             Rules.apply(
               enrolled,
               envelope("claim-owned", :claim, claim_args),
               %{principal: @pm}
             )

    assert {:error, :operator_required, %{scope: :service}} =
             Rules.apply(
               enrolled,
               envelope("pause-denied", :pause, %{expected_revision: 1}),
               %{principal: @pm}
             )

    assert {:error, :invalid_scope, %{scope: "unknown"}} =
             Rules.apply(
               enrolled,
               envelope("pause-scope", :pause, %{scope: "unknown", expected_revision: 1}),
               %{principal: @operator}
             )

    assert {:error, :project_required, %{}} =
             Rules.apply(
               enrolled,
               envelope("cancel-project-nil", :cancel, %{claim_args | project_id: nil}),
               %{principal: @pm}
             )

    assert {:error, :project_required, %{}} =
             Rules.apply(
               enrolled,
               envelope("cancel-project-empty", :cancel, %{claim_args | project_id: ""}),
               %{principal: @pm}
             )

    assert {:error, :invalid_argument, %{argument: :assignments}} =
             Rules.apply(
               enrolled,
               envelope("handoff-empty", :handoff, %{project_id: "PVT_kwDO", assignments: []}),
               %{principal: @pm}
             )

    assert {:error, :invalid_argument, %{argument: :assignments}} =
             Rules.apply(
               enrolled,
               envelope("handoff-nonlist", :handoff, %{project_id: "PVT_kwDO", assignments: :bad}),
               %{principal: @pm}
             )

    assert {:error, :invalid_argument, %{argument: :assignments}} =
             Rules.apply(
               enrolled,
               envelope("handoff-nonmap", :handoff, %{project_id: "PVT_kwDO", assignments: [:bad]}),
               %{principal: @pm}
             )

    assert {:error, :invalid_argument, %{argument: :assignments}} =
             Rules.apply(
               enrolled,
               envelope("handoff-no-id", :handoff, %{project_id: "PVT_kwDO", assignments: [%{}]}),
               %{principal: @pm}
             )

    duplicate_fence = [%{assignment_id: "issue-1"}, %{assignment_id: "issue-1"}]

    assert {:error, :duplicate_assignment, %{assignment_id: "issue-1"}} =
             Rules.apply(
               enrolled,
               envelope("handoff-duplicate", :handoff, %{project_id: "PVT_kwDO", assignments: duplicate_fence}),
               %{principal: @pm}
             )

    principal_conflict_request = envelope("principal-conflict", :enroll, enrollment_args("conflict", 1))
    {:ok, enrolled_once, _} = Rules.apply(state, principal_conflict_request, %{principal: %{principal_id: "pm-a", role: :pm, project_scope: :all}})

    assert {:error, :request_principal_conflict, %{request_id: "principal-conflict"}} =
             Rules.apply(enrolled_once, principal_conflict_request, %{principal: %{principal_id: "pm-b", role: :pm, project_scope: :all}})
  end

  test "handoff and takeover defensive branches preserve ownership fences" do
    enrolled = enrolled_state("handoff")
    target = %{principal_id: "target", role: :pm, project_scope: :all}

    handoff_args = %{
      project_id: "PVT_kwDO",
      destination_pm_id: "target",
      assignments: [%{assignment_id: "handoff", expected_revision: 1, expected_ownership_revision: 1}],
      reason: "handoff"
    }

    assert {:error, :invalid_argument, %{argument: :destination_pm_id}} =
             Rules.apply(
               enrolled,
               envelope("handoff-no-target", :handoff, Map.delete(handoff_args, :destination_pm_id)),
               %{principal: @pm}
             )

    assert {:error, :target_principal_not_registered, %{principal_id: "target"}} =
             Rules.apply(
               enrolled,
               envelope("handoff-unregistered", :handoff, handoff_args),
               %{principal: @pm}
             )

    {:ok, registered, _} =
      Rules.apply(enrolled, envelope("register-target", :register_pm, %{}), %{principal: target})

    same_source = %{handoff_args | destination_pm_id: "pm"}

    assert {:error, :target_principal_same_as_source, %{}} =
             Rules.apply(
               registered,
               envelope("handoff-same-source", :handoff, same_source),
               %{principal: @pm}
             )

    missing_fence = %{assignment_id: "missing", expected_revision: 1, expected_ownership_revision: 1}
    missing_assignment = %{handoff_args | assignments: [missing_fence]}

    assert {:error, :assignment_not_found, %{}} =
             Rules.apply(
               registered,
               envelope("handoff-missing", :handoff, missing_assignment),
               %{principal: @pm}
             )

    pending = %{principal_context: %{principal_id: "pm"}, status: :pending, assignment_id: "handoff"}

    with_intents =
      registered
      |> put_in([:effect_intents, "effect"], pending)
      |> put_in([:review_intents, "review"], pending)

    assert {:ok, transferred, _} =
             Rules.apply(
               with_intents,
               envelope("handoff-effects-reconciled", :handoff, handoff_args),
               %{principal: @pm, effects_reconciled: true}
             )

    assert transferred.effect_intents["effect"].status == :stale_owner
    assert transferred.review_intents["review"].status == :stale_owner

    unassigned =
      registered
      |> put_in([:assignments, "handoff", :ownership], %{
        status: :unassigned,
        pm_id: nil,
        capability_id: nil,
        ownership_revision: 0
      })

    unowned_fence = %{assignment_id: "handoff", expected_revision: 1, expected_ownership_revision: 0}
    takeover_args = %{handoff_args | assignments: [unowned_fence]}

    assert {:ok, taken, _} =
             Rules.apply(
               unassigned,
               envelope("operator-takeover", :operator_takeover, takeover_args),
               %{principal: @operator}
             )

    assert taken.assignments["handoff"].ownership.pm_id == "target"
  end

  test "acceptance cannot attach findings intended for a subsequent worker turn" do
    state = enrolled_state("peer-review") |> put_in([:assignments, "peer-review", :phase], :review)

    args = %{
      assignment_id: "peer-review",
      expected_revision: 1,
      disposition: "accepted",
      evidence: ["verified"],
      peer_report_refs: [%{source_assignment_id: "source", source_attempt_id: "attempt", report_id: "report"}]
    }

    assert {:error, :invalid_argument, %{argument: :peer_report_refs}} =
             prepare_request(state, envelope("accept-with-peer-context", :review, args))
  end

  test "request history remains bounded after many valid operations" do
    state =
      Enum.reduce(1..101, Rules.new(), fn index, state ->
        assert {:ok, next_state, _response} =
                 apply_request(
                   state,
                   envelope("pause-#{index}", :pause, %{expected_revision: index - 1})
                 )

        next_state
      end)

    assert map_size(state.requests) == 100
    assert state.control_revision == 101
    assert Rules.snapshot(state).cursor == 101
  end
end
