defmodule SymphonyElixir.ManagedGitHubEffectsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Managed.GitHubEffects

  @requirements "Create the fixture artifact and test it."
  @statuses ~w(READY ACTIVE REVIEW ACCEPTED WAITING CANCELLED)

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
    {:ok, provider} = Agent.start_link(fn -> initial_provider() end)
    Process.put({__MODULE__, :provider}, provider)
    Req.default_options(adapter: __MODULE__, retry: false)
    on_exit(fn -> Req.default_options(original_options) end)
    %{provider: provider}
  end

  test "partial acceptance retries only the uncompleted issue close", %{provider: provider} do
    Agent.update(provider, &%{&1 | fail_close: true})

    assert {:error, :managed_issue_close_failed, _} = GitHubEffects.review(assignment(), %{}, context())
    assert %{status: "ACCEPTED", issue_state: "OPEN", status_writes: 1, close_writes: 1} = snapshot(provider)

    Agent.update(provider, &%{&1 | fail_close: false})

    assert {:ok, %{reconciled: true, external_effects: %{status: :ok, issue_close: :ok}}} =
             GitHubEffects.review(assignment(), %{}, context())

    assert %{status: "ACCEPTED", issue_state: "CLOSED", reason: "COMPLETED", status_writes: 1, close_writes: 2} =
             snapshot(provider)

    assert {:ok, %{reconciled: true}} = GitHubEffects.review(assignment(), %{}, context())
    assert %{status_writes: 1, close_writes: 2} = snapshot(provider)
  end

  test "provider status write failure cannot close the issue", %{provider: provider} do
    Agent.update(provider, &%{&1 | fail_status: true})
    assert {:error, :managed_project_status_failed, _} = GitHubEffects.review(assignment(), %{}, context())
    assert %{status: "REVIEW", issue_state: "OPEN", status_writes: 1, close_writes: 0} = snapshot(provider)
  end

  test "changed source requirements prohibit review writes", %{provider: provider} do
    Agent.update(provider, &%{&1 | body: "New requirements invalidate old evidence."})
    assert {:error, :requirements_changed, %{}} = GitHubEffects.review(assignment(), %{}, context())
    assert %{status_writes: 0, close_writes: 0} = snapshot(provider)
  end

  test "unconfirmed process stop prohibits all provider requests", %{provider: provider} do
    assert {:error, :managed_process_not_stopped, %{}} =
             GitHubEffects.review(assignment(), %{}, %{context() | process_stopped: false})

    assert %{requests: 0, status_writes: 0, close_writes: 0} = snapshot(provider)
  end

  defp assignment do
    %{
      assignment_id: "PVTI_fixture",
      project_item_id: "PVTI_fixture",
      repository: "fixture-owner/repository",
      issue_number: 1,
      requirements_fingerprint: "sha256:" <> Base.encode16(:crypto.hash(:sha256, @requirements), case: :lower)
    }
  end

  defp context do
    %{
      process_stopped: true,
      binding: %{project_id: "PVT_fixture", status_field_id: "FIELD_status", status_options: status_options()}
    }
  end

  defp initial_provider do
    %{
      status: "REVIEW",
      issue_state: "OPEN",
      reason: nil,
      body: @requirements,
      fail_status: false,
      fail_close: false,
      requests: 0,
      status_writes: 0,
      close_writes: 0
    }
  end

  defp snapshot(provider), do: Agent.get(provider, & &1)
  defp status_options, do: Map.new(@statuses, &{&1, "option-#{&1}"})

  def run(request), do: provider_request(request, Process.get({__MODULE__, :provider}))

  defp provider_request(request, provider) do
    assert request.url.host == "github.test"
    payload = request.body |> IO.iodata_to_binary() |> Jason.decode!()
    body = Agent.get_and_update(provider, &provider_reply(payload, %{&1 | requests: &1.requests + 1}))
    {request, Req.Response.new(status: 200, body: body)}
  end

  defp provider_reply(%{"query" => query, "variables" => variables}, state) do
    cond do
      String.contains?(query, "SymphonyManagedSetProjectStatus") -> update_status(variables, state)
      String.contains?(query, "SymphonyManagedCloseIssue") -> close_issue(variables, state)
      String.contains?(query, "ProjectFields") -> {fields_body(), state}
      String.contains?(query, "ProjectItemsById") -> {%{"data" => %{"nodes" => [item(state)]}}, state}
      String.contains?(query, "SymphonyGitHubUserProject") -> {project_body(), state}
      true -> raise "Unexpected fixture GraphQL operation"
    end
  end

  defp update_status(variables, state) do
    assert variables == %{
             "projectId" => "PVT_fixture",
             "itemId" => "PVTI_fixture",
             "fieldId" => "FIELD_status",
             "optionId" => "option-ACCEPTED"
           }

    updated = %{state | status_writes: state.status_writes + 1}

    if state.fail_status do
      {failure_body(), updated}
    else
      {%{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_fixture"}}}}, %{updated | status: "ACCEPTED"}}
    end
  end

  defp close_issue(variables, state) do
    assert variables == %{"issueId" => "I_fixture"}
    updated = %{state | close_writes: state.close_writes + 1}

    if state.fail_close do
      {failure_body(), updated}
    else
      {%{"data" => %{"closeIssue" => %{"issue" => %{"id" => "I_fixture", "state" => "CLOSED", "stateReason" => "COMPLETED"}}}}, %{updated | issue_state: "CLOSED", reason: "COMPLETED"}}
    end
  end

  defp failure_body, do: %{"errors" => [%{"message" => "Synthetic provider write failure"}]}
  defp project_body, do: %{"data" => %{"user" => %{"projectV2" => %{"id" => "PVT_fixture", "number" => 1}}}}
  defp page_info, do: %{"hasNextPage" => false, "endCursor" => nil}

  defp fields_body do
    field = %{
      "__typename" => "ProjectV2SingleSelectField",
      "id" => "FIELD_status",
      "name" => "Status",
      "options" => Enum.map(status_options(), fn {name, id} -> %{"id" => id, "name" => name} end)
    }

    %{"data" => %{"node" => %{"fields" => %{"nodes" => [field], "pageInfo" => page_info()}}}}
  end

  defp item(state) do
    %{
      "id" => "PVTI_fixture",
      "project" => %{"id" => "PVT_fixture"},
      "isArchived" => false,
      "fieldValueByName" => %{"name" => state.status},
      "content" => %{
        "__typename" => "Issue",
        "id" => "I_fixture",
        "number" => 1,
        "title" => "Fixture",
        "body" => state.body,
        "state" => state.issue_state,
        "stateReason" => state.reason,
        "url" => "https://github.test/fixture-owner/repository/issues/1",
        "repository" => %{
          "id" => "R_fixture",
          "name" => "repository",
          "nameWithOwner" => "fixture-owner/repository",
          "owner" => %{"login" => "fixture-owner"},
          "url" => "https://github.test/fixture-owner/repository"
        },
        "labels" => %{"nodes" => [], "pageInfo" => page_info()},
        "blockedBy" => %{"nodes" => [], "pageInfo" => page_info()}
      }
    }
  end
end
