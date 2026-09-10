defmodule SymphonyElixir.Managed.ProjectionTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Managed.Projection

  test "handoff supersedes a delayed summary receipt without changing requirements" do
    now = ~U[2026-01-01 00:00:00Z]
    original = fixture()
    pending = Projection.mark_changes(%{assignments: %{}}, original, now)
    assert [{"item", %{projection: %{revision: 1}}}] = Projection.ready(pending, now)
    synced = Projection.finish(pending, "item", 1, :ok, now)
    assert Projection.ready(synced, now) == []

    handed_off = put_in(synced, [:assignments, "item", :ownership, :pm_id], "pm-two")
    pending_new_owner = Projection.mark_changes(synced, handed_off, now)
    assert pending_new_owner.assignments["item"].projection.revision == 2
    assert Projection.finish(pending_new_owner, "item", 1, :ok, now) == pending_new_owner
    assert pending_new_owner.assignments["item"].requirements == "Original issue requirements"
    assert Projection.text(pending_new_owner, pending_new_owner.assignments["item"]) =~ "PM: Second PM"
  end

  test "failed projection remains visible, backs off, and excludes private blocker details" do
    now = ~U[2026-01-01 00:00:00Z]
    pending = Projection.mark_changes(%{assignments: %{}}, fixture(), now)
    failed = Projection.finish(pending, "item", 1, {:error, :provider_down}, now)
    assert failed.assignments["item"].projection.status == :failed
    assert Projection.ready(failed, DateTime.add(now, 29)) == []
    assert length(Projection.ready(failed, DateTime.add(now, 30))) == 1
    text = Projection.text(failed, failed.assignments["item"])
    assert text =~ "PM review required"
    assert text =~ "Workers: 0 active"
    refute text =~ "private path"
    refute text =~ "Original issue requirements"
    assert Projection.finish(failed, "missing", 1, :ok, now) == failed
  end

  test "usage-only changes do not resynchronize cards and unconfigured Projects remain disabled" do
    original = fixture()
    usage_update = put_in(original, [:assignments, "item", :usage], %{total_tokens: 500})
    assert Projection.mark_changes(original, usage_update) == usage_update
    unconfigured = put_in(original, [:projects, "project", :projection_field_id], nil)
    assert Projection.mark_changes(%{assignments: %{}}, unconfigured) == unconfigured
  end

  test "successful live receipt records its synchronization time" do
    pending = Projection.mark_changes(%{assignments: %{}}, fixture())
    synced = Projection.finish(pending, "item", 1, :ok)
    assert synced.assignments["item"].projection.status == :synced
    assert %DateTime{} = synced.assignments["item"].projection.synced_at
  end

  defp fixture do
    %{
      projects: %{"project" => %{projection_field_id: "summary-field"}},
      principals: %{"pm-one" => %{display_name: "First PM"}, "pm-two" => %{display_name: "Second PM"}},
      assignments: %{
        "item" => %{
          project_id: "project",
          phase: :review,
          ownership: %{pm_id: "pm-one"},
          worker_active: false,
          blocked_reason: "private path",
          requirements: "Original issue requirements"
        }
      }
    }
  end
end
