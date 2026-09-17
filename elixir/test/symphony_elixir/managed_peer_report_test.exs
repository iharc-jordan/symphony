defmodule SymphonyElixir.ManagedPeerReportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.Rules

  test "invalid or excessive peer references return actionable unavailable context" do
    assert {:unavailable, %{code: :peer_report_context_invalid}} = Rules.peer_report_context(nil, %{})

    reference = %{source_assignment_id: "source", source_attempt_id: "attempt", report_id: "report"}

    for refs <- [:invalid, [:invalid], List.duplicate(reference, 9)] do
      target = %{review_feedback: %{peer_report_refs: refs}}
      assert {:unavailable, %{code: :invalid_argument}} = Rules.peer_report_context(Rules.new(), target)
    end
  end

  test "malformed stored reports cannot manufacture source provenance" do
    ownership = %{status: :owned, pm_id: "pm", capability_id: "cap", ownership_revision: 1}
    reference = %{source_assignment_id: "source", source_attempt_id: "attempt", report_id: "report"}
    target = %{project_id: "project", ownership: ownership, review_feedback: %{peer_report_refs: [reference]}}

    for stored_report <- [:error, %{attempt_id: "different-attempt", report_id: "report"}] do
      source = %{
        assignment_id: "source",
        project_id: "project",
        ownership: ownership,
        reports: %{Rules.report_key("attempt", "report") => stored_report}
      }

      state = Rules.new(assignments: %{"source" => source})

      assert {:unavailable, %{code: :peer_report_not_found}} = Rules.peer_report_context(state, target)
    end
  end

  test "peer context resolves only the exact same-project report owned by the current PM" do
    ownership = %{status: :owned, pm_id: "pm-1", capability_id: "cap", ownership_revision: 1}

    source =
      %{
        assignment_id: "source",
        project_id: "project-1",
        ownership: ownership,
        reports: %{
          Rules.report_key("source-attempt", "report-1") => %{
            attempt_id: "source-attempt",
            report_id: "report-1",
            kind: "result",
            summary: "The parser finding is confirmed.",
            evidence: ["reproduction"]
          }
        }
      }

    target =
      %{
        assignment_id: "target",
        project_id: "project-1",
        ownership: ownership,
        review_feedback: %{
          reason: "Apply the finding.",
          evidence: [],
          peer_report_refs: [%{source_assignment_id: "source", source_attempt_id: "source-attempt", report_id: "report-1"}]
        }
      }

    state = Rules.new(assignments: %{"source" => source, "target" => target})

    assert {:ok,
            [
              %{
                source_assignment_id: "source",
                source_attempt_id: "source-attempt",
                report_id: "report-1",
                summary: "The parser finding is confirmed."
              }
            ]} = Rules.peer_report_context(state, target)

    mismatched_attempt =
      put_in(target, [:review_feedback, :peer_report_refs], [
        %{source_assignment_id: "source", source_attempt_id: "other-attempt", report_id: "report-1"}
      ])

    assert {:unavailable, %{code: :peer_report_not_found}} = Rules.peer_report_context(state, mismatched_attempt)

    unrelated = put_in(source, [:project_id], "other-project")
    denied_state = %{state | assignments: %{"source" => unrelated, "target" => target}}
    assert {:unavailable, %{code: :peer_report_access_denied}} = Rules.peer_report_context(denied_state, target)
  end
end
