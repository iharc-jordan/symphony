defmodule SymphonyElixir.ManagedV2GateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.{Migration, Ownership, Projection, Resources}

  @pm_a %{principal_id: "pm-a", role: :pm, project_scope: :all, capability_id: "cap-a"}
  @pm_b %{principal_id: "pm-b", role: :pm, project_scope: ["project-1"], capability_id: "cap-b"}

  test "ownership authorization preserves a serialized PM fence" do
    assignment = %{
      "project_id" => "project-1",
      "ownership" => %{
        "status" => :owned,
        "pm_id" => "pm-a",
        "capability_id" => "cap-a",
        "ownership_revision" => 4
      },
      assignment_id: "item"
    }

    assert Ownership.owner?(assignment, @pm_a)
    assert :ok = Ownership.authorize_assignment(@pm_a, assignment, "project-1")

    assert {:error, :ownership_conflict, %{assignment_id: "item", responsible_pm_id: "pm-a"}} =
             Ownership.authorize_assignment(@pm_b, assignment, "project-1")

    assert {:error, :assignment_project_mismatch, %{project_id: "project-2", assignment_project_id: "project-1"}} =
             Ownership.authorize_assignment(@pm_a, assignment, "project-2")

    assert {:error, :principal_invalid, %{project_id: "project-1"}} =
             Ownership.authorize_project(%{role: :unknown}, "project-1")
  end

  test "resource canonicalization protects repository and path overlap boundaries" do
    assert {:ok, repository} =
             Resources.normalize(%{
               "kind" => "repo",
               "authority" => "https://github.com/",
               "identity" => "Acme/Repo.git",
               "access" => "write"
             })

    assert {:ok, path} =
             Resources.normalize(%{
               "kind" => "path",
               "authority" => "GitHub",
               "identity" => "Acme/Repo/src/./feature/../lib",
               "access" => "read"
             })

    assert repository == %{kind: :repository, authority: "github.com", identity: "acme/repo", access: :write}
    assert path == %{kind: :path, authority: "github.com", identity: "acme/repo/src/lib", access: :read}
    assert Resources.overlaps?(repository, path)
    assert Resources.conflicts?(repository, path)

    assert {:ok, sibling} =
             Resources.normalize(%{kind: :path, authority: "github", identity: "Acme/Repo/Library", access: :write})

    refute Resources.overlaps?(path, sibling)

    assert {:ok, windows_path} =
             Resources.normalize(%{kind: :path, authority: "gitlab.example", identity: "Team\\Repo\\src\\..\\lib", access: :read})

    assert windows_path.identity == "Team/Repo/lib"

    assert {:error, :resource_path_invalid, %{}} =
             Resources.normalize(%{kind: :path, authority: "gitlab.example", identity: "..\\outside", access: :read})
  end

  test "migration exposes version identity and malformed state errors" do
    assert Migration.current_version() == 2
    assert Migration.migrated?(%{version: 2})
    refute Migration.migrated?(%{version: 1})
    refute Migration.migrated?(:invalid)

    state = %{version: 2, marker: :preserved}
    assert {:ok, ^state} = Migration.migrate(state)
    assert {:error, :managed_state_invalid, %{}} = Migration.migrate(:invalid)
  end

  test "migration accepts an unbound journal and rejects invalid bindings or assignments" do
    assert {:ok, migrated} = Migration.migrate(v1_state(binding: nil))
    assert migrated.projects == %{}
    assert migrated.migration.status == :complete
    refute Map.has_key?(migrated, :binding)

    assert {:error, :project_binding_invalid, %{}} =
             Migration.migrate(v1_state(binding: %{project_id: "   "}))

    assert {:error, :project_binding_invalid, %{}} = Migration.migrate(v1_state(binding: :invalid))

    assert {:error, :assignments_invalid, %{}} = Migration.migrate(v1_state(assignments: :invalid))

    assert {:error, :assignment_invalid, %{assignment_id: "bad"}} =
             Migration.migrate(v1_state(assignments: %{"bad" => :invalid}))
  end

  test "migration records native and canonical issue identities without inventing incomplete ones" do
    native =
      assignment("native",
        provider: "linear",
        repository: "Acme/Repo",
        native_repository_id: " R-1 ",
        native_issue_id: " I-1 "
      )

    canonical = assignment("canonical", repository: "Acme/Repo", issue_number: 7)
    incomplete = assignment("incomplete", repository: "Acme/Repo", issue_number: "7")

    assert {:ok, migrated} =
             Migration.migrate(v1_state(assignments: %{"native" => native, "canonical" => canonical, "incomplete" => incomplete}))

    assert migrated.assignments["native"].underlying_identity == %{
             provider: "linear",
             repository: "Acme/Repo",
             native_repository_id: "R-1",
             native_issue_id: "I-1"
           }

    assert migrated.assignments["canonical"].underlying_identity == %{
             provider: "github",
             repository: "acme/repo",
             issue_number: 7
           }

    refute Map.has_key?(migrated.assignments["incomplete"], :underlying_identity)
    assert migrated.migration.conflicts == []
  end

  test "migration holds pending legacy intents and preserves completed history" do
    assignment = assignment("item")

    state =
      v1_state(
        assignments: %{"item" => assignment},
        review_intents: %{
          "pending" => %{request: %{args: %{assignment_id: "item"}}, status: "pending"},
          "done" => %{request: %{args: %{assignment_id: "item"}}, status: :complete},
          "orphan" => %{status: :complete},
          "malformed_args" => %{request: %{args: :invalid}, status: :complete},
          "raw" => :legacy
        },
        effect_intents: :invalid
      )

    assert {:ok, migrated} = Migration.migrate(state)

    pending = migrated.review_intents["pending"]
    assert pending.assignment_id == "item"
    assert pending.project_id == "project-1"
    assert pending.ownership_revision == 0
    assert pending.status == :needs_operator_reconciliation
    assert pending.principal_context.principal_id == "operator"
    assert pending.binding == migrated.projects["project-1"]

    assert migrated.review_intents["done"].status == :complete
    refute Map.has_key?(migrated.review_intents["orphan"], :assignment_id)
    refute Map.has_key?(migrated.review_intents["malformed_args"], :assignment_id)
    assert migrated.effect_intents == %{}
    assert migrated.assignments["item"].operator_reconciliation_required
    assert migrated.migration.reconciliation_required == ["pending"]
  end

  test "migration normalizes binding keys and attributes request records to the operator" do
    state =
      v1_state(
        binding: %{
          "project_id" => " project-1 ",
          "revision" => 3,
          "dispatch_paused" => true,
          "status_field_id" => "status"
        },
        principals: :invalid,
        requests: %{
          "record" => %{principal_id: "existing", response: %{"status" => "ok"}},
          "raw" => :preserve
        }
      )

    assert {:ok, migrated} = Migration.migrate(state)
    assert migrated.projects["project-1"].revision == 3
    assert migrated.projects["project-1"].dispatch_paused
    assert migrated.projects["project-1"].status_field_id == "status"

    assert migrated.principals == %{
             "operator" => %{principal_id: "operator", role: :operator, project_scope: :all, legacy: true}
           }

    assert migrated.requests["record"].principal_id == "existing"
    assert migrated.requests["record"].capability_id == nil
    assert migrated.requests["record"].legacy_request
    assert migrated.requests["raw"] == :preserve
  end

  test "migration leaves a non-map request collection untouched" do
    assert {:ok, migrated} = Migration.migrate(v1_state(requests: :invalid))
    assert migrated.requests == :invalid
  end

  test "projection invalidates changed responsibility fields and ignores stale receipts" do
    now = ~U[2026-01-01 00:00:00Z]

    previous = %{
      projects: %{"project-1" => %{projection_field_id: "summary"}},
      principals: %{"pm-a" => %{display_name: "PM A"}},
      assignments: %{
        "item" => %{
          project_id: "project-1",
          phase: :working,
          ownership: %{pm_id: "pm-a"},
          worker_active: true,
          stop_pending: false,
          dispatch_paused: false,
          blocked_reason: nil,
          projection: %{status: :synced, revision: 4, updated_at: now}
        }
      }
    }

    current = put_in(previous, [:assignments, "item", :stop_pending], true)
    pending = Projection.mark_changes(previous, current, now)
    assert pending.assignments["item"].projection == %{status: :pending, revision: 5, updated_at: now}
    assert [{"item", _}] = Projection.ready(pending, now)
    assert [{"item", _}] = Projection.ready(pending)

    failed =
      put_in(pending, [:assignments, "item", :projection], %{
        status: :failed,
        revision: 5,
        updated_at: now,
        error: :github_projection_failed,
        retry_at: DateTime.add(now, 30, :second)
      })

    synced = Projection.finish(failed, "item", 5, :ok, now)
    assert synced.assignments["item"].projection.status == :synced
    refute Map.has_key?(synced.assignments["item"].projection, :error)
    refute Map.has_key?(synced.assignments["item"].projection, :retry_at)
    assert Projection.finish(synced, "item", 4, :ok, now) == synced
  end

  test "projection text sanitizes and bounds the public principal label" do
    display_name = String.duplicate("N", 125) <> "\n\tsecret"

    data = %{
      principals: %{"pm-a" => %{display_name: display_name}},
      assignments: %{}
    }

    assignment = %{
      ownership: %{pm_id: "pm-a"},
      phase: :queued,
      worker_active: true,
      projection: %{updated_at: nil}
    }

    text = Projection.text(data, assignment)
    assert text =~ "PM: #{String.duplicate("N", 120)} (pm-a)"
    refute text =~ "\n"
    refute text =~ "\t"
    assert text =~ "Workers: 1 active"
    assert text =~ "Work: queued"
  end

  defp project_binding do
    %{project_id: "project-1", project_number: 1, status_field_id: "status", status_options: %{"READY" => "ready"}}
  end

  defp assignment(id, overrides \\ []) do
    base = %{assignment_id: id, project_id: "project-1", resources: []}
    Map.merge(base, Map.new(overrides))
  end

  defp v1_state(overrides) do
    base = %{
      version: 1,
      binding: project_binding(),
      assignments: %{},
      principals: %{},
      requests: %{},
      review_intents: %{},
      effect_intents: %{}
    }

    Map.merge(base, Map.new(overrides))
  end
end
