defmodule SymphonyElixir.ManagedV2GateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.{Ownership, Projection, Resources}

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
end
