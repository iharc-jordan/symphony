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
    assert Rules.phase("attacker_supplied_atom_name") == :unknown
    assert Rules.phase(:attacker_supplied_atom_name) == :unknown
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

    request = envelope("revise-active", :revise, %{assignment_id: "issue-1", expected_revision: 2, stop_reconciled: true, changes: %{route: %{model: "gpt-5.6-terra", effort: "max"}}})
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
        changes: %{route: %{model: "gpt-5.6-terra", effort: "max"}, stop_pending: false}
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
end
