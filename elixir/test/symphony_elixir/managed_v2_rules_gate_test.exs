defmodule SymphonyElixir.ManagedV2RulesGateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.{Ownership, Rules}

  @project_id "PVT_gate"
  @operator %{principal_id: "operator", role: :operator, project_scope: :all}
  @pm %{principal_id: "pm-a", role: :pm, project_scope: :all}
  @target_pm %{principal_id: "pm-b", role: :pm, project_scope: :all}

  test "claim assigns an unowned enrollment and enforces the ownership revision fence" do
    state =
      enrolled_state("claim")
      |> put_in([:assignments, "claim", :ownership], Ownership.unassigned())

    request =
      envelope("claim-ok", :claim, %{
        project_id: @project_id,
        assignment_id: "claim",
        expected_revision: 1,
        expected_ownership_revision: 0
      })

    assert {:ok, claimed, response} = Rules.apply(state, request, %{principal: @pm})
    assert response.ownership_revision == 1
    assert claimed.assignments["claim"].ownership.status == :owned
    assert claimed.assignments["claim"].ownership.pm_id == "pm-a"

    stale =
      put_in(state, [:assignments, "claim", :ownership], %{
        Ownership.unassigned()
        | ownership_revision: 4
      })

    assert {:error, :stale_ownership_revision, %{expected: 0, actual: 4}} =
             Rules.apply(stale, request, %{principal: @pm})
  end

  test "assignment pause and resume require project and per-assignment fences" do
    state = enrolled_state("paused")

    fence = %{assignment_id: "paused", expected_revision: 1, expected_ownership_revision: 1}

    pause =
      envelope("pause-assignment", :pause, %{
        scope: "assignments",
        project_id: @project_id,
        assignments: [fence]
      })

    assert {:ok, paused, %{scope: :assignments}} = Rules.apply(state, pause, %{principal: @pm})
    assert paused.assignments["paused"].dispatch_paused
    assert paused.control_revision == state.control_revision + 1

    resume =
      envelope("resume-assignment", :resume, %{
        scope: "assignments",
        project_id: @project_id,
        assignments: [fence]
      })

    assert {:ok, resumed, %{scope: :assignments}} = Rules.apply(paused, resume, %{principal: @pm})
    refute resumed.assignments["paused"].dispatch_paused

    wrong_project = Map.put(pause, :args, Map.put(pause.args, :project_id, "PVT_other"))

    assert {:error, :assignment_project_mismatch, %{project_id: "PVT_other"}} =
             Rules.apply(state, wrong_project, %{principal: @pm})
  end

  test "handoff blocks while owned effects are uncertain and invalidates old-owner intents after reconciliation" do
    state = enrolled_state("handoff")
    register = envelope("register-target", :register_pm, %{display_name: "Target PM"})

    assert {:ok, registered, _} = Rules.apply(state, register, %{principal: @target_pm})

    handoff_args = %{
      project_id: @project_id,
      destination_pm_id: "pm-b",
      assignments: [%{assignment_id: "handoff", expected_revision: 1, expected_ownership_revision: 1}],
      handoff_id: "handoff-1",
      reason: "coverage handoff"
    }

    pending =
      put_in(
        registered,
        [:effect_intents],
        %{"effect-1" => %{assignment_id: "handoff", status: :pending}}
      )

    assert {:error, :handoff_effect_pending, %{}} =
             Rules.apply(pending, envelope("handoff-blocked", :handoff, handoff_args), %{principal: @pm})

    reconciled =
      put_in(
        registered,
        [:effect_intents],
        %{"effect-1" => %{assignment_id: "handoff", ownership_revision: 1, status: :pending}}
      )

    assert {:ok, transferred, response} =
             Rules.apply(
               reconciled,
               envelope("handoff-ok", :handoff, handoff_args),
               %{principal: @pm, effects_reconciled: true}
             )

    assert response.destination_pm_id == "pm-b"
    assert transferred.assignments["handoff"].ownership.pm_id == "pm-b"
    assert transferred.effect_intents["effect-1"].status == :stale_owner
    assert transferred.effect_intents["effect-1"].stale_owner_id == "pm-a"
  end

  test "binding projection metadata and malformed source identity fail closed" do
    binding_request =
      envelope(
        "bind-projection",
        :bind_project,
        binding_args() |> put_in([:project, :projection_field_id], "FIELD_summary")
      )

    assert {:ok, bound, _} = Rules.apply(Rules.new(), binding_request, %{principal: @operator})
    assert bound.projects[@project_id].projection_field_id == "FIELD_summary"

    invalid_projection =
      binding_args() |> put_in([:project, :projection_field_id], 42)

    assert {:error, :invalid_argument, %{argument: :projection_field_id}} =
             Rules.apply(Rules.new(), envelope("bind-invalid-projection", :bind_project, invalid_projection), %{principal: @operator})

    enrollment =
      enrollment_args("source-fallback", 1)

    assert {:ok, enrolled, _} =
             Rules.apply(
               bound,
               envelope("enroll-malformed-source", :enroll, enrollment),
               %{principal: @pm, source_identity: :malformed}
             )

    refute Map.has_key?(enrolled.assignments["source-fallback"], :title)
    refute Map.has_key?(enrolled.assignments["source-fallback"], :issue_url)

    malformed_binding =
      Rules.new(projects: %{@project_id => Map.delete(bound.projects[@project_id], :repositories)})

    assert {:error, :project_not_bound, %{}} =
             Rules.apply(
               malformed_binding,
               envelope("enroll-malformed-binding", :enroll, enrollment_args("bad-binding", 0)),
               %{principal: @pm}
             )
  end

  test "string control envelopes normalize all managed wire keys and preserve principal requirements" do
    request = %{
      "request_id" => "wire-pause",
      "operation" => "pause",
      "args" => %{
        "expected_revision" => 0,
        "scope" => "service",
        "assignment_ids" => ["ignored"],
        "assignments" => [],
        "expected_ownership_revision" => 1,
        "expected_revisions" => %{"item" => 1},
        "expected_ownership_revisions" => %{"item" => 1},
        "destination_pm_id" => "pm-b",
        "project_item_id" => "item",
        "native_issue_id" => "issue",
        "native_repository_id" => "repository",
        "status_field_id" => "field",
        "projection_field_id" => "summary",
        "project_number" => 1,
        "status_options" => %{"READY" => "ready"},
        "repositories" => ["acme/example"],
        "provider" => "github",
        "repository" => "acme/example",
        "issue_number" => 1,
        "base_commit" => "base",
        "board_state" => "READY",
        "phase" => "READY",
        "route" => %{"model" => "gpt-5.6-luna", "effort" => "xhigh"},
        "resources" => [],
        "dependencies" => [],
        "changes" => %{},
        "disposition" => "waiting",
        "provider_state" => "REVIEW",
        "evidence" => ["proof"],
        "reason" => "reason",
        "disable" => false,
        "principal" => %{"principal_id" => "nested"},
        "target_principal_id" => "pm-b",
        "handoff_id" => "handoff",
        "display_name" => "display name",
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
    }

    assert {:ok, paused, %{scope: :service, paused: true}} =
             Rules.apply(
               Rules.new(),
               request,
               %{principal_context: %{"principal_id" => "operator", "role" => "operator", "project_scope" => "all"}}
             )

    assert paused.paused
    assert {:error, :principal_required, %{}} = Rules.authorize(Rules.new(), request, %{unrelated: true})

    assert {:error, :unsupported_operation, %{operation: :bind_project}} =
             Rules.prepare_review(Rules.new(), %{request_id: "prepare-bind", operation: :bind_project, args: %{}}, %{principal: @operator})

    assert Rules.resources_available?(%{}, :invalid) == false
  end

  test "revision validates optional dependency lists without accepting malformed values" do
    state = enrolled_state("revision")

    valid =
      envelope("revision-dependencies", :revise, %{
        assignment_id: "revision",
        project_id: @project_id,
        expected_revision: 1,
        expected_ownership_revision: 1,
        changes: %{dependencies: ["other-assignment"], base_commit: "new-base"}
      })

    assert {:ok, revised, _} = Rules.apply(state, valid, %{principal: @pm})
    assert revised.assignments["revision"].dependencies == ["other-assignment"]

    invalid =
      envelope("revision-bad-dependencies", :revise, %{
        assignment_id: "revision",
        project_id: @project_id,
        expected_revision: 1,
        expected_ownership_revision: 1,
        changes: %{dependencies: "other-assignment"}
      })

    assert {:error, :invalid_argument, %{argument: :dependencies}} =
             Rules.apply(state, invalid, %{principal: @pm})
  end

  test "project requirement snapshots fence enrollment and refresh on revision" do
    requirements_path = Path.expand("../fixtures/REQUIREMENTS.md", __DIR__)
    binding = put_in(binding_args(), [:project, :requirements_path], requirements_path)

    assert {:ok, bound, _} =
             Rules.apply(Rules.new(), envelope("bind-requirements", :bind_project, binding), %{principal: @operator})

    assert {:error, :project_requirements_path_invalid} =
             Rules.apply(
               Rules.new(),
               envelope("bind-invalid-requirements", :bind_project, put_in(binding_args(), [:project, :requirements_path], "relative/REQUIREMENTS.md")),
               %{principal: @operator}
             )

    initial_fingerprint = "sha256:requirements-one"

    assert {:ok, enrolled, _} =
             Rules.apply(
               bound,
               envelope("enroll-requirements", :enroll, enrollment_args("requirements", 1)),
               %{"project_requirements" => %{fingerprint: initial_fingerprint}, principal: @pm}
             )

    assert enrolled.assignments["requirements"].project_requirements_fingerprint == initial_fingerprint

    assert {:error, :project_requirements_snapshot_required, %{}} =
             Rules.apply(
               bound,
               envelope("enroll-requirements-missing", :enroll, enrollment_args("requirements-missing", 1)),
               %{principal: @pm, project_requirements: %{}}
             )

    refreshed_fingerprint = "sha256:requirements-two"

    revise =
      envelope("revise-requirements", :revise, %{
        assignment_id: "requirements",
        project_id: @project_id,
        expected_revision: 1,
        expected_ownership_revision: 1,
        changes: %{base_commit: "refreshed-base"}
      })

    assert {:ok, revised, _} =
             Rules.apply(
               enrolled,
               revise,
               %{principal: @pm, project_requirements: %{fingerprint: refreshed_fingerprint}}
             )

    assert revised.assignments["requirements"].project_requirements_fingerprint == refreshed_fingerprint
    assert enrolled.assignments["requirements"].project_requirements_fingerprint == initial_fingerprint
  end

  test "malformed contexts and project shapes fail closed while free resources remain available" do
    request = envelope("malformed-context", :pause, %{expected_revision: 0})

    assert {:error, :principal_required, %{}} =
             Rules.apply(Rules.new(), request, :malformed_context)

    assert Rules.resources_available?(Rules.new(), %{assignment_id: "free", resources: []})

    malformed_projects = Rules.new(projects: %{@project_id => :malformed})

    assert {:error, :project_not_bound, %{}} =
             Rules.apply(
               malformed_projects,
               envelope("malformed-project-entry", :enroll, enrollment_args("bad-project", 0)),
               %{principal: @pm}
             )
  end

  test "new state starts without a project and binding creates its project entry" do
    assert Rules.new().projects == %{}

    assert {:ok, bound, _} =
             Rules.apply(
               Rules.new(),
               envelope("bind-new-project", :bind_project, binding_args()),
               %{principal: @operator}
             )

    assert bound.projects[@project_id].project_id == @project_id
    assert bound.projects[@project_id].revision == 1
  end

  test "operator takeover and handoff preserve fences across missing, pending, and malformed state" do
    state = enrolled_state("takeover")
    register = envelope("register-takeover-target", :register_pm, %{display_name: "Target PM"})

    assert {:ok, registered, _} = Rules.apply(state, register, %{principal: @target_pm})

    args = %{
      project_id: @project_id,
      destination_pm_id: "pm-b",
      assignments: [
        %{assignment_id: "takeover", expected_revision: 1, expected_ownership_revision: 1}
      ],
      handoff_id: "takeover-1",
      reason: "operator takeover"
    }

    missing = %{args | assignments: [%{assignment_id: "missing"}]}

    assert {:error, :assignment_not_found, %{}} =
             Rules.apply(
               registered,
               envelope("takeover-missing", :operator_takeover, missing),
               %{principal: @operator}
             )

    wrong_project = %{args | project_id: "PVT_other"}

    assert {:error, :assignment_project_mismatch, %{project_id: "PVT_other"}} =
             Rules.apply(
               registered,
               envelope("takeover-wrong-project", :operator_takeover, wrong_project),
               %{principal: @operator}
             )

    missing_revision = %{
      args
      | assignments: [%{assignment_id: "takeover", expected_ownership_revision: 1}]
    }

    assert {:error, :expected_revision_required, %{assignment_id: "takeover"}} =
             Rules.apply(
               registered,
               envelope("takeover-missing-revision", :operator_takeover, missing_revision),
               %{principal: @operator}
             )

    missing_ownership = %{
      args
      | assignments: [%{assignment_id: "takeover", expected_revision: 1}]
    }

    assert {:error, :expected_ownership_revision_required, %{assignment_id: "takeover"}} =
             Rules.apply(
               registered,
               envelope("takeover-missing-ownership", :operator_takeover, missing_ownership),
               %{principal: @operator}
             )

    stale_ownership = %{
      args
      | assignments: [
          %{assignment_id: "takeover", expected_revision: 1, expected_ownership_revision: 0}
        ]
    }

    assert {:error, :stale_ownership_revision, %{assignment_id: "takeover", expected: 0, actual: 1}} =
             Rules.apply(
               registered,
               envelope("takeover-stale-ownership", :operator_takeover, stale_ownership),
               %{principal: @operator}
             )

    pause_missing_fence = %{
      scope: "assignments",
      project_id: @project_id,
      assignments: [%{assignment_id: "takeover"}]
    }

    assert {:error, :expected_revision_required, %{assignment_id: "takeover"}} =
             Rules.apply(
               registered,
               envelope("pause-missing-fence", :pause, pause_missing_fence),
               %{principal: @pm}
             )

    pending =
      put_in(registered, [:assignments, "takeover", :stop_pending], true)

    assert {:error, :handoff_effect_pending, %{}} =
             Rules.apply(
               pending,
               envelope("takeover-stop-pending", :operator_takeover, args),
               %{principal: @operator}
             )

    malformed_intents = %{registered | effect_intents: :malformed, review_intents: :malformed}

    assert {:ok, taken, _} =
             Rules.apply(
               malformed_intents,
               envelope("takeover-malformed-intents", :operator_takeover, args),
               %{principal: @operator}
             )

    assert taken.effect_intents == :malformed
    assert taken.review_intents == :malformed

    owner_shape = %{
      registered
      | effect_intents: %{
          "effect-malformed" => :malformed,
          "effect-owner-shape" => %{
            assignment_id: "takeover",
            principal_context: :malformed,
            status: :pending
          }
        },
        review_intents: %{
          "review-owner-shape" => %{
            assignment_id: "takeover",
            principal_context: :malformed,
            status: :pending
          }
        }
    }

    assert {:ok, owner_shape_taken, _} =
             Rules.apply(
               owner_shape,
               envelope("takeover-owner-shape", :operator_takeover, args),
               %{principal: @operator, effects_reconciled: true}
             )

    assert owner_shape_taken.effect_intents["effect-owner-shape"].status == :pending

    handoff_error =
      put_in(registered, [:assignments, "takeover", :ownership], Ownership.unassigned())

    handoff_args = %{args | assignments: [%{assignment_id: "takeover", expected_revision: 1, expected_ownership_revision: 0}]}

    assert {:error, :assignment_not_owned, %{assignment_id: "takeover"}} =
             Rules.apply(
               handoff_error,
               envelope("handoff-unowned", :handoff, handoff_args),
               %{principal: @operator}
             )

    takeover_error =
      put_in(registered, [:assignments, "takeover", :ownership, :status], :handoff_pending)

    pending_fence = %{assignment_id: "takeover", expected_revision: 1, expected_ownership_revision: 1}

    assert {:error, :assignment_not_takeoverable, %{assignment_id: "takeover"}} =
             Rules.apply(
               takeover_error,
               envelope("takeover-pending", :operator_takeover, %{args | assignments: [pending_fence]}),
               %{principal: @operator}
             )
  end

  test "binding replacement fences active work only in the affected project" do
    state = enrolled_state("binding-rebind")

    same_binding = binding_args() |> Map.put(:expected_revision, state.control_revision)

    assert {:ok, rebound, _} =
             Rules.apply(
               state,
               envelope("binding-rebind-same", :bind_project, same_binding),
               %{principal: @operator}
             )

    assert rebound.projects[@project_id].revision == 2

    changed_binding =
      binding_args()
      |> Map.put(:expected_revision, state.control_revision)
      |> put_in([:project, :project_number], 8)

    assert {:error, :binding_in_use, %{assignment_id: "binding-rebind"}} =
             Rules.apply(
               state,
               envelope("binding-rebind-conflict", :bind_project, changed_binding),
               %{principal: @operator}
             )

    other_project =
      binding_args()
      |> Map.put(:expected_revision, state.control_revision)
      |> put_in([:project, :project_id], "PVT_other")

    assert {:ok, expanded, _} =
             Rules.apply(
               state,
               envelope("binding-rebind-other-project", :bind_project, other_project),
               %{principal: @operator}
             )

    assert expanded.projects["PVT_other"].project_id == "PVT_other"
  end

  test "binding replacement ignores malformed inactive entries when no active owner exists" do
    binding = binding_args() |> Map.fetch!(:project)
    project = Map.merge(binding, %{revision: 0, dispatch_paused: false})
    malformed_state = Rules.new(projects: %{@project_id => project}, assignments: %{"malformed" => :malformed})

    other_project =
      binding_args()
      |> Map.put(:expected_revision, 0)
      |> put_in([:project, :project_id], "PVT_other")

    assert {:ok, replaced, _} =
             Rules.apply(
               malformed_state,
               envelope("malformed-assignment-binding", :bind_project, other_project),
               %{principal: @operator}
             )

    assert replaced.projects["PVT_other"].project_id == "PVT_other"
  end

  test "revision accepts normalized resources and rejected enrollment ignores obsolete owner inputs" do
    state = enrolled_state("resource-revision")

    resource = %{kind: :database, authority: "Acme.DB", identity: "Primary", access: :write}

    request =
      envelope("resource-revision", :revise, %{
        assignment_id: "resource-revision",
        project_id: @project_id,
        expected_revision: 1,
        expected_ownership_revision: 1,
        changes: %{resources: [resource]}
      })

    assert {:ok, revised, _} = Rules.apply(state, request, %{principal: @pm})

    assert revised.assignments["resource-revision"].resources == [
             %{kind: :database, authority: "acme.db", identity: "primary", access: :write}
           ]

    owner_enrollment = enrollment_args("obsolete-owner", 1) |> Map.put(:owner, "display-only")

    assert {:error, :invalid_argument, %{argument: :owner}} =
             Rules.apply(bind_state(), envelope("obsolete-owner", :enroll, owner_enrollment), %{principal: @pm})
  end

  test "request replay requires a recorded trusted principal" do
    request = envelope("missing-principal", :pause, %{expected_revision: 0})
    state = Rules.new(requests: %{"missing-principal" => %{canonical: Rules.canonical_input(request), response: %{operation: :pause}}})

    assert {:error, :request_principal_conflict, %{request_id: "missing-principal"}} =
             Rules.apply(state, request, %{principal: @operator})
  end

  test "binding replacement handles malformed assignments in an existing project slot" do
    binding = binding_args() |> Map.fetch!(:project)
    project = Map.merge(binding, %{revision: 0, dispatch_paused: false})
    state = Rules.new(projects: %{@project_id => project}, assignments: %{"malformed" => :malformed})

    replacement =
      binding_args()
      |> put_in([:project, :project_number], 8)

    assert {:ok, replaced, _} =
             Rules.apply(
               state,
               envelope("replace-malformed-project-slot", :bind_project, replacement),
               %{principal: @operator}
             )

    assert replaced.projects[@project_id].project_number == 8
  end

  defp binding_args do
    %{
      expected_revision: 0,
      project: %{
        project_id: @project_id,
        project_number: 7,
        status_field_id: "FIELD_status",
        status_options: %{
          "READY" => "option-ready",
          "ACTIVE" => "option-active",
          "REVIEW" => "option-review",
          "ACCEPTED" => "option-accepted",
          "WAITING" => "option-waiting",
          "CANCELLED" => "option-cancelled"
        },
        repositories: ["acme/example"]
      }
    }
  end

  defp enrollment_args(id, expected_revision) do
    %{
      expected_revision: expected_revision,
      assignment_id: id,
      repository: "acme/example",
      issue_number: 12,
      base_commit: "base-commit",
      board_state: "READY",
      project_id: @project_id,
      resources: [],
      dependencies: [],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"}
    }
  end

  defp envelope(id, operation, args), do: %{request_id: id, operation: operation, args: args}

  defp bind_state do
    assert {:ok, state, _} =
             Rules.apply(Rules.new(), envelope("bind", :bind_project, binding_args()), %{principal: @operator})

    state
  end

  defp enrolled_state(id) do
    assert {:ok, state, _} =
             Rules.apply(
               bind_state(),
               envelope("enroll-" <> id, :enroll, enrollment_args(id, 1)),
               %{principal: @pm}
             )

    state
  end
end

defmodule SymphonyElixir.ManagedV2GitHubEffectsGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.GitHubEffects

  setup do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github_projects
      provider:
        owner_type: user
        owner: fixture-owner
        project_number: 1
        status_field_name: Status
        token: fixture-token
        graphql_url: https://github.test/graphql
      active_states: [READY, ACTIVE, REVIEW, WAITING]
      terminal_states: [ACCEPTED, CANCELLED]
    ---
    Fixture workflow.
    """)

    :ok = WorkflowStore.force_reload()
    original_options = Req.default_options()
    {:ok, provider} = Agent.start_link(fn -> [] end)
    Process.put({__MODULE__, :provider}, provider)
    Req.default_options(adapter: __MODULE__, retry: false)
    on_exit(fn -> Req.default_options(original_options) end)
    %{provider: provider}
  end

  test "summary uses the assignment identity fallback, caps text, and rejects an unconfirmed item", %{provider: provider} do
    assignment = %{assignment_id: "PVTI_gate", project_id: "PVT_gate"}
    binding = %{project_id: "PVT_gate", projection_field_id: "FIELD_summary"}
    summary = String.duplicate("S", 1_100)

    assert :ok = GitHubEffects.project_summary(assignment, binding, summary)

    [payload] = Agent.get(provider, & &1)
    assert payload["variables"]["projectId"] == "PVT_gate"
    assert payload["variables"]["itemId"] == "PVTI_gate"
    assert payload["variables"]["fieldId"] == "FIELD_summary"
    assert byte_size(payload["variables"]["text"]) == 1_024

    Application.put_env(:symphony_elixir, :managed_github_request_fun, fn _payload ->
      {:ok, %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "other-item"}}}}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :managed_github_request_fun) end)

    assert {:error, :managed_projection_unconfirmed} =
             GitHubEffects.project_summary(assignment, binding, "still bounded")
  end

  test "summary refuses a project mismatch or missing operational field before a provider request", %{provider: provider} do
    assignment = %{assignment_id: "PVTI_gate", project_id: "PVT_gate"}

    assert {:error, :managed_projection_unconfirmed} =
             GitHubEffects.project_summary(
               assignment,
               %{project_id: "PVT_other", projection_field_id: "FIELD_summary"},
               "wrong project"
             )

    assert {:error, :managed_projection_unconfirmed} =
             GitHubEffects.project_summary(
               assignment,
               %{project_id: "PVT_gate", projection_field_id: nil},
               "missing field"
             )

    assert Agent.get(provider, & &1) == []
  end

  def run(request) do
    assert request.url.host == "github.test"
    payload = request.body |> IO.iodata_to_binary() |> Jason.decode!()
    Agent.update(Process.get({__MODULE__, :provider}), &[payload | &1])

    body = %{
      "data" => %{
        "updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_gate"}}
      }
    }

    {request, Req.Response.new(status: 200, body: body)}
  end
end
