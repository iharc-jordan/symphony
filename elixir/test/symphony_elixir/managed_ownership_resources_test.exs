defmodule SymphonyElixir.ManagedOwnershipResourcesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.{Ownership, Resources}

  @pm_a %{principal_id: "pm-a", role: :pm, project_scope: :all, capability_id: "cap-a"}
  @pm_b %{principal_id: "pm-b", role: :pm, project_scope: ["P1"], capability_id: "cap-b"}
  @operator %{principal_id: "operator", role: :operator, project_scope: :all, capability_id: nil}

  describe "ownership" do
    test "normalizes principals and rejects invalid contexts" do
      assert {:ok, %{principal_id: "pm-a", role: :pm, project_scope: :all, capability_id: "cap"}} =
               Ownership.principal(%{principal: %{principal_id: " pm-a ", role: " PM ", project_scope: "all", capability_id: " cap "}})

      assert {:ok, %{principal_id: "op", role: :operator, project_scope: ["P1", "P2"]}} =
               Ownership.principal(%{"principal" => %{"principal_id" => "op", "role" => "operator", "project_scope" => [" P1 ", "P1", "P2"]}})

      assert {:ok, %{project_scope: scope}} =
               Ownership.principal(%{principal_id: "pm", role: :pm, project_scope: MapSet.new(["P1"])})

      assert scope == MapSet.new(["P1"])

      for context <- [nil, "token", %{principal: nil}, %{principal: "token"}] do
        assert {:error, :principal_required, %{}} = Ownership.principal(context)
      end

      assert {:error, :principal_required, %{}} = Ownership.principal(%{principal_id: "  ", role: :pm})
      assert {:error, :principal_invalid, %{}} = Ownership.principal(%{principal_id: "pm", role: "unknown"})
      assert {:error, :principal_invalid, %{}} = Ownership.principal(%{principal_id: "pm", role: 1})

      assert {:error, :principal_scope_invalid, %{}} =
               Ownership.principal(%{principal_id: "pm", role: :pm, project_scope: 1})

      assert {:error, :principal_scope_invalid, %{}} =
               Ownership.principal(%{principal_id: "pm", role: :pm, project_scope: ["P1", 2]})
    end

    test "authorizes projects, assignments, and ownership revisions" do
      assigned = Ownership.assigned(@pm_a, 2)
      assignment = %{assignment_id: "item", project_id: "P1", ownership: assigned}

      assert Ownership.unassigned().status == :unassigned
      assert Ownership.needs_claim().status == :needs_claim
      assert %DateTime{} = assigned.changed_at
      assert Ownership.assigned(@pm_a).ownership_revision == 1
      assert Ownership.project_allowed?(@pm_a, "P1")
      assert Ownership.project_allowed?(@pm_b, "P1")
      assert Ownership.project_allowed?(%{@pm_b | project_scope: MapSet.new(["P2"])}, "P2")
      refute Ownership.project_allowed?(@pm_b, "P2")
      refute Ownership.project_allowed?(%{@pm_b | project_scope: :invalid}, "P1")
      refute Ownership.project_allowed?(@pm_b, nil)
      refute Ownership.project_allowed?(@pm_b, 42)
      assert Ownership.operator?(@operator)
      refute Ownership.operator?(@pm_a)
      assert Ownership.owner?(assignment, @pm_a)
      refute Ownership.owner?(assignment, @pm_b)
      refute Ownership.owner?("invalid", @pm_a)
      refute Ownership.owner?(%{}, %{})

      assert {:error, :project_required, %{}} = Ownership.authorize_project(@pm_a, nil)
      assert {:error, :project_required, %{}} = Ownership.authorize_project(@pm_a, "")
      assert :ok = Ownership.authorize_project(@operator, "any")
      assert :ok = Ownership.authorize_project(@pm_b, "P1")
      assert {:error, :project_out_of_scope, %{project_id: "P2"}} = Ownership.authorize_project(@pm_b, "P2")
      assert {:error, :principal_invalid, %{project_id: "P1"}} = Ownership.authorize_project(%{role: :unknown}, "P1")

      assert :ok = Ownership.authorize_assignment(@operator, %{assignment | ownership: Ownership.unassigned()}, "P1")
      assert :ok = Ownership.authorize_assignment(@pm_a, assignment, "P1")

      assert {:error, :assignment_unowned, %{assignment_id: "item"}} =
               Ownership.authorize_assignment(@pm_b, %{assignment | ownership: Ownership.unassigned()}, "P1")

      assert {:error, :ownership_conflict, %{assignment_id: "item", responsible_pm_id: "pm-a"}} =
               Ownership.authorize_assignment(@pm_b, assignment, "P1")

      assert {:error, :assignment_project_mismatch, %{project_id: "P1", assignment_project_id: "P2"}} =
               Ownership.authorize_assignment(@pm_a, %{assignment | project_id: "P2"}, "P1")

      assert {:error, :assignment_invalid, %{project_id: "P1"}} =
               Ownership.authorize_assignment(@pm_a, :invalid, "P1")

      assert {:error, :expected_ownership_revision_required, %{}} =
               Ownership.expected_ownership_revision(assignment, %{})

      assert {:error, :stale_ownership_revision, %{expected: 1, actual: 2}} =
               Ownership.expected_ownership_revision(assignment, %{expected_ownership_revision: 1})

      assert :ok = Ownership.expected_ownership_revision(assignment, %{"expected_ownership_revision" => 2})

      assert {:error, :expected_ownership_revision_required, %{}} =
               Ownership.expected_ownership_revision(:invalid, %{})
    end

    test "claims, transfers, and takes over assignments" do
      assignment = %{assignment_id: "item", project_id: "P1", ownership: Ownership.unassigned()}

      assert {:ok, claimed} = Ownership.claim(assignment, @pm_a)
      assert claimed.ownership.status == :owned
      assert claimed.ownership.ownership_revision == 1

      for {status, error} <- [
            {:needs_claim, :operator_takeover_required},
            {:owned, :ownership_conflict},
            {:handoff_pending, :handoff_pending}
          ] do
        rejected = %{assignment | ownership: %{Ownership.unassigned() | status: status}}
        assert {:error, ^error, %{assignment_id: "item"}} = Ownership.claim(rejected, @pm_b)
      end

      owned = %{assignment | ownership: Ownership.assigned(@pm_a, 4)}
      assert {:ok, transferred} = Ownership.transfer(owned, @pm_b, "handoff-1")
      assert transferred.ownership.pm_id == "pm-b"
      assert transferred.ownership.capability_id == "cap-b"
      assert transferred.ownership.ownership_revision == 5
      assert transferred.ownership.last_handoff_id == "handoff-1"
      assert %DateTime{} = transferred.ownership.changed_at

      assert {:error, :assignment_not_owned, %{assignment_id: "item"}} =
               Ownership.transfer(assignment, @pm_b)

      assert {:error, :assignment_not_owned, %{assignment_id: "item"}} =
               Ownership.transfer(owned, @operator)

      for status <- [:needs_claim, :unassigned, :owned] do
        candidate = %{owned | ownership: %{Ownership.unassigned() | status: status, ownership_revision: 7}}
        assert {:ok, taken_over} = Ownership.takeover(candidate, @pm_b, "takeover-#{status}")
        assert taken_over.ownership.status == :owned
        assert taken_over.ownership.pm_id == "pm-b"
        assert taken_over.ownership.ownership_revision == 8
      end

      pending = %{owned | ownership: %{Ownership.unassigned() | status: :handoff_pending}}

      assert {:error, :assignment_not_takeoverable, %{assignment_id: "item"}} =
               Ownership.takeover(pending, @pm_b)

      assert {:error, :assignment_not_takeoverable, %{assignment_id: "item"}} =
               Ownership.takeover(owned, @operator)
    end

    test "normalizes ownership maps and safe fallbacks" do
      assert Ownership.ownership("invalid") == Ownership.unassigned()
      assert Ownership.ownership(%{ownership: nil}) == Ownership.unassigned()

      assert %{status: :handoff_pending, pm_id: "pm", capability_id: nil, ownership_revision: 0, last_handoff_id: "handoff"} =
               Ownership.ownership(%{
                 "ownership" => %{
                   "status" => :handoff_pending,
                   "pm_id" => " pm ",
                   "capability_id" => 42,
                   "ownership_revision" => -1,
                   "last_handoff_id" => " handoff "
                 }
               })
    end
  end

  describe "resources" do
    test "normalizes canonical references and all aliases" do
      assert Resources.kinds() == [:repository, :path, :database, :deployment, :other]

      assert {:ok, %{kind: :repository, authority: "github.com", identity: "acme/one", access: :write}} =
               Resources.normalize(%{kind: "repo", authority: " HTTPS://github.com/ ", identity: "https://GitHub.com/Acme/One.git", access: " WRITE "})

      assert {:ok, %{kind: :path, authority: "github.com", identity: "acme/one/lib", access: :read}} =
               Resources.normalize(%{kind: "path", authority: "github", identity: "Acme/One/src/../lib", access: "read"})

      assert {:ok, %{kind: :path, authority: "gitlab.example", identity: "Team/Repo/lib", access: :read}} =
               Resources.normalize(%{kind: "path", authority: " GitLab.Example/ ", identity: "Team/Repo/./lib", access: :read})

      for {kind, authority, identity, access, canonical} <- [
            {"database", "Postgres", "Cluster/Main", :read, %{kind: :database, authority: "postgres", identity: "cluster/main", access: :read}},
            {"db", "Postgres", "Cluster/Main", :read, %{kind: :database, authority: "postgres", identity: "cluster/main", access: :read}},
            {"deployment", "Vercel", "Production", :write, %{kind: :deployment, authority: "vercel", identity: "production", access: :write}},
            {"deploy", "Vercel", "Production", :write, %{kind: :deployment, authority: "vercel", identity: "production", access: :write}},
            {"other", "Vendor", "Opaque", :read, %{kind: :other, authority: "vendor", identity: "opaque", access: :read}}
          ] do
        assert {:ok, ^canonical} =
                 Resources.normalize(%{kind: kind, authority: authority, identity: identity, access: access})
      end
    end

    test "rejects malformed resource references" do
      assert {:error, :resource_reference_required, %{resource: "acme/one"}} = Resources.normalize("acme/one")
      assert {:error, :resource_reference_required, %{resource: "   "}} = Resources.normalize("   ")
      assert {:error, :resource_reference_required, %{resource: :invalid}} = Resources.normalize(:invalid)

      for {resource, error} <- [
            {%{kind: "unknown", authority: "x", identity: "y", access: "read"}, :invalid_resource_kind},
            {%{kind: 1, authority: "x", identity: "y", access: "read"}, :invalid_resource_kind},
            {%{kind: "database", authority: " ", identity: "y", access: "read"}, :resource_authority_required},
            {%{kind: "database", authority: nil, identity: "y", access: "read"}, :resource_authority_required},
            {%{kind: "database", authority: "x", identity: " ", access: "read"}, :resource_identity_required},
            {%{kind: "database", authority: "x", identity: nil, access: "read"}, :resource_identity_required},
            {%{kind: "database", authority: "x", identity: "y", access: "admin"}, :invalid_resource_access},
            {%{kind: "database", authority: "x", identity: "y", access: 1}, :invalid_resource_access},
            {%{kind: "repository", authority: "/", identity: "acme/one", access: :read}, :resource_identity_required},
            {%{kind: "repository", authority: "x", identity: "/", access: :read}, :resource_identity_required},
            {%{kind: "path", authority: "github.com", identity: "owner", access: :read}, :resource_path_invalid},
            {%{kind: "path", authority: "github.com", identity: "../outside", access: :read}, :resource_path_invalid},
            {%{kind: "path", authority: "gitlab.example", identity: "/", access: :read}, :resource_identity_required}
          ] do
        assert {:error, ^error, %{}} = Resources.normalize(resource)
      end
    end

    test "normalizes lists and coalesces read/write access" do
      repository = resource(:repository, "github.com", "acme/one", :read)
      writer = resource(:repository, "github.com", "acme/one", :write)
      database = resource(:database, "postgres", "cluster/main", :read)

      coalesced = %{repository | access: :write}
      assert {:ok, [^coalesced, ^database]} = Resources.normalize_all([repository, writer, database])

      assert {:error, :resource_reference_required, %{resource: "bad"}} = Resources.normalize_all([repository, "bad"])
      assert {:error, :resources_must_be_list, %{resources: :bad}} = Resources.normalize_all(:bad)
    end

    test "detects overlap, access conflicts, and invalid candidates" do
      repository = resource(:repository, "github.com", "acme/one", :read)
      repository_child = resource(:repository, "github.com", "acme/one/service", :write)
      path = resource(:path, "github.com", "acme/one/src", :read)
      path_child = resource(:path, "github.com", "acme/one/src/lib", :write)
      other_path = resource(:path, "github.com", "acme/one/test", :read)
      database = resource(:database, "postgres", "cluster/main", :read)
      same_database = resource(:database, "postgres", "cluster/main", :write)
      other_database = resource(:database, "postgres", "cluster/other", :write)
      deployment = resource(:deployment, "postgres", "production", :write)

      assert Resources.overlaps?(repository, repository)
      assert Resources.overlaps?(repository, repository_child)
      assert Resources.overlaps?(repository_child, repository)
      assert Resources.overlaps?(repository, path)
      assert Resources.overlaps?(path, path_child)
      refute Resources.overlaps?(path, other_path)
      refute Resources.overlaps?(repository, resource(:repository, "gitlab.example", "acme/one", :write))
      assert Resources.overlaps?(database, same_database)
      refute Resources.overlaps?(database, other_database)
      refute Resources.overlaps?(database, repository)
      refute Resources.overlaps?(database, deployment)
      refute Resources.overlaps?(repository, :invalid)
      refute Resources.overlaps?(nil, repository)

      refute Resources.conflicts?(repository, path)
      assert Resources.conflicts?(repository, repository_child)
      assert Resources.conflicts?(database, same_database)
      refute Resources.conflicts?(database, other_database)
      assert Resources.conflicts?(deployment, deployment)
      refute Resources.conflicts?(deployment, resource(:deployment, "vercel", "staging", :write))
      refute Resources.conflicts?(:bad, deployment)
      assert Resources.writable?(repository_child)
      refute Resources.writable?(repository)
      refute Resources.writable?(%{})

      assert {:ok, :free} = Resources.conflict(repository, [path, database])

      assert {:error, :resource_conflict, %{resource: ^repository, conflicting_resource: ^repository_child}} =
               Resources.conflict(repository, [repository_child])

      assert {:error, :resources_invalid, %{}} = Resources.conflict(repository, :bad)
      assert {:error, :resources_invalid, %{}} = Resources.conflict(:bad, [])
    end
  end

  defp resource(kind, authority, identity, access) do
    %{kind: kind, authority: authority, identity: identity, access: access}
  end
end
