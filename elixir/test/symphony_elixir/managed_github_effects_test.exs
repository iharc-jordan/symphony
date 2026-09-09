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

  test "transitions reconcile each native board state and retries do not write twice", %{provider: provider} do
    for target <- [:ready, :active, :review, :waiting, :cancelled] do
      Agent.update(provider, fn _ -> initial_provider() end)

      assert {:ok, %{provider_state: ^target, reconciled: true}} =
               GitHubEffects.transition(assignment(), target, context())

      writes = snapshot(provider).status_writes
      assert {:ok, %{provider_state: ^target}} = GitHubEffects.transition(assignment(), target, context())
      assert snapshot(provider).status_writes == writes
      assert snapshot(provider).close_writes == 0
    end
  end

  test "canceled alias reconciles without writes and unknown state cannot be accepted", %{provider: provider} do
    Agent.update(provider, &%{&1 | status: "CANCELED"})
    assert {:ok, %{provider_state: :cancelled}} = GitHubEffects.transition(assignment(), :cancelled)
    assert snapshot(provider).status_writes == 0
    Agent.update(provider, &%{&1 | status: "UNRECOGNIZED"})

    assert {:error, :managed_provider_state_mismatch, %{actual: :unknown}} =
             GitHubEffects.review(assignment(), %{}, context())
  end

  test "stopped process is required for leaving active work", %{provider: provider} do
    for target <- [:ready, :waiting, :cancelled] do
      assert {:error, :managed_process_not_stopped, %{}} =
               GitHubEffects.transition(assignment(), target, %{process_stopped: false})
    end

    assert snapshot(provider).status_writes == 0
    assert {:error, :managed_process_not_stopped, %{}} = GitHubEffects.review(assignment(), %{})
  end

  test "identity and fingerprint errors prohibit all mutations", %{provider: provider} do
    cases = [
      {Map.delete(assignment(), :assignment_id), :invalid_assignment_identity},
      {%{assignment() | repository: "other/repository"}, :managed_native_identity_mismatch},
      {%{assignment() | issue_number: 2}, :managed_native_identity_mismatch},
      {%{assignment() | project_item_id: "PVTI_other"}, :managed_native_identity_mismatch},
      {Map.delete(assignment(), :requirements_fingerprint), :requirements_fingerprint_missing},
      {%{assignment() | requirements_fingerprint: "invalid"}, :invalid_requirements_fingerprint}
    ]

    for {invalid, expected} <- cases do
      assert {:error, ^expected, _} = GitHubEffects.review(invalid, %{}, context())
    end

    assert %{status_writes: 0, close_writes: 0} = snapshot(provider)
  end

  test "missing or malformed provider items prohibit writes", %{provider: provider} do
    Agent.update(provider, &%{&1 | item_mode: :missing})
    assert {:error, :managed_native_item_not_found, %{}} = GitHubEffects.review(assignment(), %{}, context())
    Agent.update(provider, &%{&1 | item_mode: :failure})

    assert {:error, :managed_native_fetch_failed, %{reason: reason}} =
             GitHubEffects.review(assignment(), %{}, context())

    assert reason =~ "graphql_errors"
    assert %{status_writes: 0, close_writes: 0} = snapshot(provider)
  end

  test "pull requests cannot be treated as native issues", %{provider: provider} do
    Agent.update(provider, &%{&1 | content_type: "PullRequest"})
    assert {:error, :managed_native_issue_required, %{}} = GitHubEffects.review(assignment(), %{}, context())
    assert snapshot(provider).status_writes == 0
  end

  test "empty native issue bodies use the empty material fingerprint", %{provider: provider} do
    Agent.update(provider, &%{&1 | body: nil})
    empty = %{assignment() | requirements_fingerprint: fingerprint("")}
    assert {:ok, %{reconciled: true}} = GitHubEffects.review(empty, %{}, context())
  end

  test "missing status binding data cannot mutate the board", %{provider: provider} do
    for options <- [[], %{}, %{"ACCEPTED" => nil}] do
      invalid_context = put_in(context(), [:binding, :status_options], options)

      assert {:error, :managed_status_option_missing, %{status: :accepted}} =
               GitHubEffects.review(assignment(), %{}, invalid_context)
    end

    invalid_context = put_in(context(), [:binding, :status_field_id], nil)

    assert {:error, :managed_project_status_identity_missing, %{}} =
             GitHubEffects.review(assignment(), %{}, invalid_context)

    assert snapshot(provider).status_writes == 0
  end

  test "mutation success must identify the exact native record", %{provider: provider} do
    Agent.update(provider, &%{&1 | malformed_status: true})
    assert {:error, :managed_project_status_unconfirmed, %{}} = GitHubEffects.review(assignment(), %{}, context())
    assert snapshot(provider).close_writes == 0
    Agent.update(provider, fn _ -> %{initial_provider() | malformed_close: true} end)
    assert {:error, :managed_issue_close_unconfirmed, %{}} = GitHubEffects.review(assignment(), %{}, context())
  end

  test "observed provider status overrides a successful mutation response", %{provider: provider} do
    Agent.update(provider, &%{&1 | ignore_status: true})

    assert {:error, :managed_provider_state_mismatch, %{expected: :accepted, actual: :review}} =
             GitHubEffects.review(assignment(), %{}, context())

    assert snapshot(provider).close_writes == 0

    assert {:error, :managed_provider_state_mismatch, %{expected: :active, actual: :review}} =
             GitHubEffects.transition(assignment(), :active, context())
  end

  test "requirements changed after status update cannot close the issue", %{provider: provider} do
    Agent.update(provider, &%{&1 | after_status: %{body: "Revised scope"}})
    assert {:error, :requirements_changed, %{}} = GitHubEffects.review(assignment(), %{}, context())
    assert snapshot(provider).close_writes == 0
  end

  test "content changed to pull request after status update cannot be closed", %{provider: provider} do
    Agent.update(provider, &%{&1 | after_status: %{content_type: "PullRequest"}})
    assert {:error, :managed_native_issue_required, %{}} = GitHubEffects.review(assignment(), %{}, context())
    assert snapshot(provider).close_writes == 0
  end

  test "closed issue requires completed reason before and after close", %{provider: provider} do
    Agent.update(provider, &%{&1 | issue_state: "CLOSED", reason: "NOT_PLANNED"})

    assert {:error, :managed_issue_closed_with_wrong_reason, %{reason: "not_planned"}} =
             GitHubEffects.review(assignment(), %{}, context())

    assert snapshot(provider).close_writes == 0
    Agent.update(provider, fn _ -> %{initial_provider() | after_close: %{reason: "NOT_PLANNED"}} end)

    assert {:error, :managed_issue_closed_with_wrong_reason, %{reason: "not_planned"}} =
             GitHubEffects.review(assignment(), %{}, context())
  end

  test "close response must agree with refetched issue state", %{provider: provider} do
    Agent.update(provider, &%{&1 | after_close: %{issue_state: "OPEN"}})
    assert {:error, :managed_issue_not_closed, %{state: "open"}} = GitHubEffects.review(assignment(), %{}, context())
  end

  test "configured provider request callback is used for mutations", %{provider: provider} do
    Application.put_env(:symphony_elixir, :managed_github_request_fun, fn payload ->
      Agent.get_and_update(provider, fn state ->
        {body, updated} = provider_reply(payload, state)
        {{:ok, body}, updated}
      end)
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :managed_github_request_fun) end)
    assert {:ok, %{reconciled: true}} = GitHubEffects.review(assignment(), %{}, context())
  end

  test "other providers and invalid workflow configuration fail closed", %{provider: provider} do
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    File.write!(path, String.replace(original, "kind: github_projects", "kind: memory"))
    :ok = WorkflowStore.force_reload()
    assert {:error, :managed_github_provider_required, %{}} = GitHubEffects.review(assignment(), %{}, context())
    File.write!(path, String.replace(original, "kind: github_projects", "kind: unsupported"))
    assert {:error, {:unsupported_tracker_kind, "unsupported"}} = WorkflowStore.force_reload()
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    try do
      assert {:error, :managed_github_provider_unavailable, %{}} = GitHubEffects.review(assignment(), %{}, context())
    after
      File.write!(path, original)
      assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    end

    assert snapshot(provider).requests == 0
  end

  defp fingerprint(body), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)

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
      content_type: "Issue",
      item_mode: :normal,
      after_status: %{},
      after_close: %{},
      ignore_status: false,
      malformed_status: false,
      malformed_close: false,
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
      String.contains?(query, "ProjectItemsById") -> items_reply(state)
      String.contains?(query, "SymphonyGitHubUserProject") -> {project_body(), state}
      true -> raise "Unexpected fixture GraphQL operation"
    end
  end

  defp update_status(variables, state) do
    assert variables["projectId"] == "PVT_fixture"
    assert variables["itemId"] == "PVTI_fixture"
    assert variables["fieldId"] == "FIELD_status"
    target = String.replace_prefix(variables["optionId"], "option-", "")
    assert target in @statuses
    updated = %{state | status_writes: state.status_writes + 1}
    status_reply(state, updated, target)
  end

  defp status_reply(%{fail_status: true}, updated, _target), do: {failure_body(), updated}
  defp status_reply(%{malformed_status: true}, updated, _target), do: {%{"data" => %{}}, updated}

  defp status_reply(state, updated, target) do
    status = if state.ignore_status, do: state.status, else: target
    body = %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_fixture"}}}}
    {body, Map.merge(%{updated | status: status}, state.after_status)}
  end

  defp close_issue(variables, state) do
    assert variables == %{"issueId" => "I_fixture"}
    updated = %{state | close_writes: state.close_writes + 1}
    close_reply(state, updated)
  end

  defp close_reply(%{fail_close: true}, updated), do: {failure_body(), updated}
  defp close_reply(%{malformed_close: true}, updated), do: {%{"data" => %{}}, updated}

  defp close_reply(state, updated) do
    body = %{"data" => %{"closeIssue" => %{"issue" => %{"id" => "I_fixture", "state" => "CLOSED", "stateReason" => "COMPLETED"}}}}
    {body, Map.merge(%{updated | issue_state: "CLOSED", reason: "COMPLETED"}, state.after_close)}
  end

  defp items_reply(%{item_mode: :missing} = state), do: {%{"data" => %{"nodes" => []}}, state}
  defp items_reply(%{item_mode: :failure} = state), do: {failure_body(), state}
  defp items_reply(state), do: {%{"data" => %{"nodes" => [item(state)]}}, state}

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
        "__typename" => state.content_type,
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
