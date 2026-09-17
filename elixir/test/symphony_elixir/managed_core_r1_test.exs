defmodule SymphonyElixir.ManagedCoreR1Test do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.{Resources, Rules}

  @operator %{principal_id: "operator", role: :operator, project_scope: :all}
  @pm_a %{principal_id: "pm-a", role: :pm, project_scope: :all}
  @pm_b %{principal_id: "pm-b", role: :pm, project_scope: :all}

  defp envelope(id, operation, args), do: %{request_id: id, operation: operation, args: args}

  defp bound do
    args = %{
      expected_revision: 0,
      project: %{
        project_id: "project-1",
        project_number: 1,
        status_field_id: "status",
        status_options: %{"READY" => "ready"},
        repositories: ["acme/repo"]
      }
    }

    {:ok, state, _} = Rules.apply(Rules.new(), envelope("bind", :bind_project, args), @operator)
    state
  end

  defp enrollment(id, revision, resource \\ %{kind: :repository, authority: "github", identity: "acme/repo", access: :write}) do
    %{
      expected_revision: revision,
      project_id: "project-1",
      assignment_id: id,
      repository: "acme/repo",
      issue_number: 1,
      base_commit: "abc",
      board_state: :ready,
      resources: [resource],
      dependencies: [],
      route: %{model: "gpt-5.6-luna", effort: "xhigh"}
    }
  end

  test "a PM enrollment records the trusted principal and owns the assignment" do
    {:ok, state, _} =
      Rules.apply(bound(), envelope("enroll", :enroll, enrollment("a", 1)), %{principal: @pm_a})

    assert state.assignments["a"].ownership.pm_id == "pm-a"
    assert state.assignments["a"].ownership.ownership_revision == 1
    assert state.principals["pm-a"].principal_id == "pm-a"
  end

  test "old PM controls are fenced after an atomic handoff" do
    {:ok, state, _} =
      Rules.apply(bound(), envelope("enroll", :enroll, enrollment("a", 1)), %{principal: @pm_a})

    {:ok, state, _} =
      Rules.apply(state, envelope("register", :register_pm, %{display_name: "B"}), %{principal: @pm_b})

    handoff = %{
      project_id: "project-1",
      destination_pm_id: "pm-b",
      assignments: [%{assignment_id: "a", expected_revision: 1, expected_ownership_revision: 1}],
      reason: "coverage"
    }

    {:ok, state, _} = Rules.apply(state, envelope("handoff", :handoff, handoff), %{principal: @pm_a})
    assert state.assignments["a"].ownership.pm_id == "pm-b"

    stale = %{
      project_id: "project-1",
      assignment_id: "a",
      expected_revision: 1,
      expected_ownership_revision: 1,
      reason: "stale"
    }

    assert {:error, :ownership_conflict, _} = Rules.apply(state, envelope("stale", :cancel, stale), %{principal: @pm_a})
  end

  test "review preparation keeps internal principal context out of the persisted wire request" do
    {:ok, state, _} = Rules.apply(bound(), envelope("enroll-review", :enroll, enrollment("review", 1)), %{principal: @pm_a})

    state =
      state
      |> put_in([:assignments, "review", :phase], :review)
      |> put_in([:assignments, "review", :board_state], :review)
      |> put_in([:assignments, "review", :revision], 2)

    request =
      envelope("prepare-review", :review, %{
        project_id: "project-1",
        assignment_id: "review",
        expected_revision: 2,
        expected_ownership_revision: 1,
        disposition: "rework",
        reason: "needs changes"
      })

    assert {:ok, intent} = Rules.prepare_review(state, request, %{principal: @pm_a})
    assert intent.request == request
    refute Map.has_key?(intent.request, :principal)
  end

  test "resource aliases normalize to one writable repository" do
    assert {:ok, a} = Resources.normalize(%{kind: :repository, authority: "GitHub", identity: "https://github.com/acme/repo.git", access: :write})
    assert {:ok, b} = Resources.normalize(%{kind: "repo", authority: "github", identity: "acme/repo", access: :read})
    assert Resources.conflicts?(a, b)
    assert {:error, :resource_reference_required, _} = Resources.normalize("repo:acme/repo")
  end

  test "resource normalization coalesces read/write and blocks repository/path aliases" do
    assert {:ok, refs} =
             Resources.normalize_all([
               %{kind: :repository, authority: "github", identity: "acme/repo", access: :read},
               %{kind: :repository, authority: "github", identity: "https://github.com/acme/repo.git", access: :write}
             ])

    assert [%{access: :write}] = refs

    assert {:ok, repository} = Resources.normalize(%{kind: :repository, authority: "github", identity: "acme/repo", access: :write})
    assert {:ok, path} = Resources.normalize(%{kind: :path, authority: "github", identity: "acme/./repo/../repo", access: :read})
    assert Resources.conflicts?(repository, path)
  end

  test "GitHub resource authorities and paths canonicalize safely" do
    assert {:ok, repository} =
             Resources.normalize(%{
               kind: :repository,
               authority: "https://github.com/",
               identity: "Acme/Repo.git",
               access: :write
             })

    assert repository.authority == "github.com"
    assert repository.identity == "acme/repo"

    assert {:ok, path} =
             Resources.normalize(%{
               kind: :path,
               authority: "GitHub",
               identity: "Acme/Repo/src/./Feature/../File.TXT",
               access: :read
             })

    assert path.authority == "github.com"
    assert path.identity == "acme/repo/src/File.TXT"

    assert {:error, :resource_path_invalid, %{}} =
             Resources.normalize(%{kind: :path, authority: "github", identity: "../repo", access: :read})

    assert {:error, :resource_path_invalid, %{}} =
             Resources.normalize(%{kind: :path, authority: "github", identity: "src", access: :read})
  end

  test "trusted source identity enriches enrollment without changing request canonical" do
    state = bound()
    args = enrollment("a", 1)
    request = envelope("enroll-source", :enroll, args)
    canonical = Rules.canonical_input(request)

    {:ok, enrolled, _} = Rules.apply(state, request, %{principal: @pm_a, source_identity: %{native_issue_id: "I-1", native_repository_id: "R-1", requirements_fingerprint: "sha256:body"}})
    assignment = enrolled.assignments["a"]
    assert assignment.native_issue_id == "I-1"
    assert assignment.native_repository_id == "R-1"
    assert assignment.requirements_fingerprint == "sha256:body"
    assert Rules.canonical_input(request) == canonical
  end

  test "dispatch resource check excludes the assignment itself" do
    state = bound()
    {:ok, state, _} = Rules.apply(state, envelope("enroll", :enroll, enrollment("a", 1)), %{principal: @pm_a})
    assert Rules.resources_available?(state, state.assignments["a"])
  end

  test "assignment pause preserves worker revision" do
    {:ok, state, _} =
      Rules.apply(bound(), envelope("enroll", :enroll, enrollment("a", 1)), %{principal: @pm_a})

    args = %{
      scope: "assignments",
      project_id: "project-1",
      assignments: [
        %{assignment_id: "a", expected_revision: 1, expected_ownership_revision: 1}
      ]
    }

    {:ok, paused, _} = Rules.apply(state, envelope("pause", :pause, args), %{principal: @pm_a})
    assert paused.assignments["a"].dispatch_paused
    assert paused.assignments["a"].revision == 1
  end
end
