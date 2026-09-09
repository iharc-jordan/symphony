defmodule SymphonyElixir.GitHubProjects.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubProjects.Adapter
  alias SymphonyElixir.GitHubProjects.Client

  test "validates project scope and tracker-level states" do
    settings = tracker_settings()

    assert :ok = Adapter.validate_config(settings)

    assert {:error, :missing_github_projects_active_states} =
             Adapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_github_projects_terminal_states} =
             Adapter.validate_config(%{settings | terminal_states: nil})

    assert {:error, :invalid_github_projects_owner_type} =
             Adapter.validate_config(%{settings | provider: Map.put(settings.provider, "owner_type", "team")})

    assert {:error, :invalid_github_projects_project_number} =
             Adapter.validate_config(%{settings | provider: Map.put(settings.provider, "project_number", "12")})

    assert {:error, :invalid_github_projects_active_states} =
             Adapter.validate_config(%{settings | active_states: ["Todo", 1]})

    assert {:error, :invalid_github_projects_terminal_states} =
             Adapter.validate_config(%{settings | terminal_states: [nil]})

    assert {:ok, []} = Adapter.fetch_issues_by_states([])
    assert {:ok, []} = Adapter.fetch_issues_by_ids([])
    assert "GITHUB_TOKEN" in Adapter.secret_environment_names(settings)
  end

  test "normalizes project identity, native repository reference, labels, and blockers" do
    item = %{
      "id" => "PVTI_1",
      "project" => %{"id" => "PVT_1"},
      "fieldValueByName" => %{"name" => "Todo"},
      "content" => %{
        "__typename" => "Issue",
        "id" => "I_1",
        "number" => 42,
        "title" => "Ship it",
        "body" => "Body",
        "state" => "OPEN",
        "url" => "https://github.test/octo/one/issues/42",
        "repository" => repository("octo", "one"),
        "labels" => %{"nodes" => [%{"name" => " Bug "}, %{"name" => "bug"}]},
        "blockedBy" => %{
          "nodes" => [%{"id" => "I_2", "number" => 7, "state" => "CLOSED", "repository" => repository("octo", "two")}],
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        },
        "createdAt" => "2026-09-09T12:00:00Z",
        "updatedAt" => "2026-09-09T13:00:00Z"
      }
    }

    issue = Client.normalize_issue_for_test(item, tracker_settings())

    assert issue.id == "PVTI_1"
    assert issue.identifier == "octo/one#42"
    assert issue.state == "Todo"
    assert issue.labels == ["bug"]
    assert issue.dispatchable
    assert issue.native_ref["project_id"] == "PVT_1"
    assert issue.native_ref["project_item_id"] == "PVTI_1"
    assert issue.native_ref["issue_id"] == "I_1"
    assert issue.native_ref["repository"]["name_with_owner"] == "octo/one"
    assert issue.native_ref["issue_number"] == 42
    assert issue.native_ref["content_type"] == "Issue"
    assert issue.blocked_by == [%{"id" => "I_2", "identifier" => "octo/two#7", "state" => "CLOSED"}]
  end

  test "pull requests are visible but never dispatchable and drafts are omitted" do
    base = %{
      "id" => "PVTI_1",
      "project" => %{"id" => "PVT_1"},
      "fieldValueByName" => %{"name" => "Todo"},
      "content" => %{
        "__typename" => "PullRequest",
        "id" => "PR_1",
        "number" => 8,
        "title" => "PR",
        "state" => "OPEN",
        "url" => "https://github.test/octo/one/pull/8",
        "repository" => repository("octo", "one")
      }
    }

    refute Client.normalize_issue_for_test(base, tracker_settings()).dispatchable

    draft = put_in(base, ["content", "__typename"], "DraftIssue")
    assert Client.normalize_issue_for_test(draft, tracker_settings()) == nil
  end

  test "pages project items and blockers and preserves item order" do
    request_fun = fn query, variables, _settings ->
      cond do
        String.contains?(query, "query SymphonyGitHubProject(") ->
          {:ok, %{status: 200, body: %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1", "number" => 9}}}}}}

        String.contains?(query, "ProjectFields") ->
          {:ok, %{status: 200, body: fields_body()}}

        String.contains?(query, "IssueBlockers") ->
          send(self(), {:blocker_page, variables["after"]})
          {:ok, %{status: 200, body: blocker_body()}}

        String.contains?(query, "ProjectItems") ->
          send(self(), {:item_page, variables["after"]})
          {:ok, %{status: 200, body: item_body(variables["after"])}}
      end
    end

    assert {:ok, issues} =
             Client.fetch_issues_by_states_for_test(["todo"], tracker_settings(), request_fun)

    assert Enum.map(issues, & &1.identifier) == ["octo/one#1", "octo/two#2"]
    assert_receive {:item_page, nil}
    assert_receive {:item_page, "cursor-1"}
    assert_receive {:blocker_page, "blocker-1"}
  end

  test "refresh uses a valid ProjectV2 item query without an unused project variable" do
    request_fun = fn query, variables, _settings ->
      cond do
        String.contains?(query, "query SymphonyGitHubProject(") ->
          {:ok, %{status: 200, body: %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1", "number" => 9}}}}}}

        String.contains?(query, "ProjectFields") ->
          {:ok, %{status: 200, body: fields_body()}}

        String.contains?(query, "ProjectItemsById") ->
          refute String.contains?(query, "$projectId")
          refute Map.has_key?(variables, "projectId")

          {:ok,
           %{
             status: 200,
             body: %{"data" => %{"nodes" => [item(1, "one", false), Map.put(item(1, "two", false), "id", "PVTI_2")]}}
           }}
      end
    end

    assert {:ok, issues} =
             Client.fetch_issues_by_ids_for_test(
               ["PVTI_1", "PVTI_2"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.identifier) == ["octo/one#1", "octo/two#1"]
  end

  test "empty reads and missing cursors fail safely" do
    request_fun = fn _query, _variables, _settings -> flunk("no provider request expected") end

    assert {:ok, []} = Client.fetch_issues_by_states_for_test([], tracker_settings(), request_fun)
    assert {:ok, []} = Client.fetch_issues_by_ids_for_test([], tracker_settings(), request_fun)

    assert {:error, :github_projects_missing_end_cursor} =
             Client.next_page_cursor_for_test(%{"hasNextPage" => true})
  end

  test "rejects malformed and repeated pagination cursors" do
    assert {:error, :github_projects_malformed_page_info} =
             Client.next_page_cursor_for_test(%{})

    request_fun = fn query, variables, _settings ->
      cond do
        String.contains?(query, "query SymphonyGitHubProject(") ->
          {:ok, %{status: 200, body: %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1"}}}}}}

        String.contains?(query, "ProjectFields") ->
          {:ok, %{status: 200, body: fields_body()}}

        String.contains?(query, "ProjectItems") ->
          page_info =
            if is_nil(variables["after"]) do
              %{"hasNextPage" => true, "endCursor" => "repeat"}
            else
              %{"hasNextPage" => true, "endCursor" => "repeat"}
            end

          body = put_in(item_body(nil), ["data", "node", "items", "pageInfo"], page_info)
          {:ok, %{status: 200, body: body}}
      end
    end

    assert {:error, :github_projects_repeated_cursor} =
             Client.fetch_issues_by_states_for_test(["todo"], tracker_settings(), request_fun)
  end

  test "unknown blocker nodes make an issue non-dispatchable" do
    item = %{
      "id" => "PVTI_1",
      "project" => %{"id" => "PVT_1"},
      "fieldValueByName" => %{"name" => "Todo"},
      "content" => %{
        "__typename" => "Issue",
        "id" => "I_1",
        "number" => 1,
        "title" => "Issue",
        "state" => "OPEN",
        "repository" => repository("octo", "one"),
        "blockedBy" => %{
          "nodes" => [nil],
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        }
      }
    }

    issue = Client.normalize_issue_for_test(item, tracker_settings())

    refute issue.dispatchable
    assert issue.blocked_by == [%{"id" => nil, "identifier" => nil, "state" => nil}]
  end

  test "public helpers cover config, request arities, response errors, and empty calls" do
    assert Client.secret_environment_names(%{provider: %{"token" => "$CUSTOM_TOKEN"}}) == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             "CUSTOM_TOKEN"
           ]

    assert Client.secret_environment_names(%{provider: %{"token" => "$BAD-NAME"}}) == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN"
           ]

    assert {:ok, %{"data" => %{}}} =
             Client.graphql("query", %{"answer" => 42},
               tracker_settings: tracker_settings(),
               request_fun: fn payload, settings ->
                 assert payload["query"] == "query"
                 assert payload["variables"] == %{"answer" => 42}

                 assert settings == %{
                          owner_type: "org",
                          owner: "octo",
                          project_number: 9,
                          status_field_name: "Status",
                          token: "test-token",
                          graphql_url: "https://api.github.com/graphql"
                        }

                 {:ok, %{status: 200, body: %{"data" => %{}}}}
               end
             )

    assert {:ok, %{"data" => %{}}} =
             Client.graphql("query", %{},
               tracker_settings: tracker_settings(),
               request_fun: fn payload ->
                 assert payload["query"] == "query"
                 {:ok, %{"data" => %{}}}
               end
             )

    assert {:error, {:github_projects_api_request, :github_projects_invalid_request_fun}} =
             Client.graphql("query", %{},
               tracker_settings: tracker_settings(),
               request_fun: fn -> :never end
             )

    assert {:error, {:github_projects_rate_limited, 403}} =
             graphql_with(fn _ -> {:ok, %{status: 403}} end)

    assert {:error, {:github_projects_rate_limited, 429}} =
             graphql_with(fn _ -> {:ok, %{status: 429}} end)

    assert {:error, {:github_projects_api_status, 500}} =
             graphql_with(fn _ -> {:ok, %{status: 500}} end)

    assert {:ok, %{"data" => %{}}} =
             graphql_with(fn _ -> {:ok, %{"data" => %{}}} end)

    assert {:ok, %{"data" => %{}}} =
             graphql_with(fn _ -> {:ok, %{"data" => %{}}} end)

    assert {:error, {:github_projects_graphql_errors, [%{"message" => "bad"}]}} =
             graphql_with(fn _ -> {:ok, %{"errors" => [%{"message" => "bad"}]}} end)

    assert {:error, :github_projects_unknown_payload} =
             graphql_with(fn _ -> {:ok, %{"other" => true}} end)

    assert {:error, {:github_projects_api_request, :timeout}} =
             graphql_with(fn _ -> {:error, :timeout} end)

    assert {:error, :github_projects_unknown_payload} =
             graphql_with(fn _ -> :unexpected end)

    assert {:ok, []} = Client.fetch_issues_by_states([])
    assert {:ok, []} = Client.fetch_issues_by_ids([])
  end

  test "validates every GitHub Projects provider setting" do
    settings = tracker_settings()

    assert :ok = Client.validate_settings(settings)

    assert {:error, :invalid_github_projects_owner_type} =
             Client.validate_settings(%{settings | provider: Map.put(settings.provider, "owner_type", "team")})

    assert {:error, :missing_github_projects_owner} =
             Client.validate_settings(%{settings | provider: Map.delete(settings.provider, "owner")})

    assert {:error, :invalid_github_projects_project_number} =
             Client.validate_settings(%{settings | provider: Map.put(settings.provider, "project_number", 0)})

    assert {:error, :invalid_github_projects_status_field_name} =
             Client.validate_settings(%{settings | provider: Map.put(settings.provider, "status_field_name", " ")})

    assert {:error, :invalid_github_projects_graphql_url} =
             Client.validate_settings(%{settings | provider: Map.put(settings.provider, "graphql_url", "http://github.test/graphql")})

    assert {:error, :missing_github_projects_token} =
             Client.validate_settings(%{settings | provider: Map.delete(settings.provider, "token")})

    assert {:error, :missing_github_projects_token} =
             Client.validate_settings(%{settings | provider: Map.put(settings.provider, "token", "$GITHUB_TOKEN")})

    assert {:error, :missing_github_projects_token} =
             Client.validate_settings(%{settings | provider: Map.put(settings.provider, "token", "$INVALID-NAME")})

    assert {:error, :invalid_github_projects_owner_type} = Client.validate_settings(%{})
  end

  test "normalizes alternate status, assignee, repository, labels, and blocker shapes" do
    base = %{
      "id" => "PVTI_alt",
      "project" => %{"id" => "PVT_1"},
      "fieldValueByName" => " Todo ",
      "content" => %{
        "type" => "Issue",
        "id" => "I_alt",
        "number" => 3,
        "title" => "Alternate",
        "state" => "OPEN",
        "repository" => %{
          "name" => "repo",
          "name_with_owner" => "octo/repo",
          "owner" => %{"login" => "octo"}
        },
        "assignees" => %{"nodes" => [%{"id" => 123}]},
        "labels" => [%{"name" => " A "}, "B", nil],
        "blockedBy" => %{"nodes" => [%{"number" => 0, "state" => %{"name" => " CLOSED "}, "repository" => nil}]}
      }
    }

    issue = Client.normalize_issue_for_test(base, tracker_settings())
    assert issue.state == "Todo"
    assert issue.assignee_id == "123"
    assert issue.labels == ["a", "b"]
    assert issue.blocked_by == [%{"id" => nil, "identifier" => nil, "state" => "CLOSED"}]
    assert issue.native_ref["repository"]["name_with_owner"] == "octo/repo"

    for value <- [" Todo ", %{"unknown" => true}, nil] do
      item = put_in(base, ["fieldValueByName"], value)
      issue = Client.normalize_issue_for_test(item, tracker_settings())
      if value == nil or value == %{"unknown" => true}, do: assert(is_nil(issue)), else: assert(issue.state == "Todo")
    end
  end

  test "handles project lookup, user scope, status pagination, and status failures" do
    missing_project = fn _query, _variables, _settings ->
      {:ok, %{status: 200, body: %{"data" => %{"organization" => nil}}}}
    end

    assert {:error, :github_projects_project_not_found} =
             fetch_states(missing_project)

    malformed_project = fn _query, _variables, _settings ->
      {:ok, %{status: 200, body: %{"data" => %{"organization" => %{"projectV2" => %{"id" => 123}}}}}}
    end

    assert {:error, :github_projects_malformed_project} =
             fetch_states(malformed_project)

    user_settings = %{tracker_settings() | provider: Map.put(tracker_settings().provider, "owner_type", "user")}

    user_request = fn query, variables, _settings ->
      cond do
        String.contains?(query, "UserProject") ->
          {:ok, %{status: 200, body: %{"data" => %{"user" => %{"projectV2" => %{"id" => "PVT_1", "number" => 9}}}}}}

        String.contains?(query, "ProjectFields") and is_nil(variables["after"]) ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "node" => %{
                   "fields" => %{
                     "nodes" => [%{"__typename" => "ProjectV2Field", "name" => "Other"}],
                     "pageInfo" => %{"hasNextPage" => true, "endCursor" => "field-1"}
                   }
                 }
               }
             }
           }}

        String.contains?(query, "ProjectFields") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "node" => %{
                   "fields" => %{
                     "nodes" => [
                       %{"__typename" => "ProjectV2SingleSelectField", "id" => "PVTF_status", "name" => "Status", "options" => %{"nodes" => [%{"id" => "opt-todo", "name" => "Todo"}, %{"id" => 4}]}}
                     ],
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                   }
                 }
               }
             }
           }}

        String.contains?(query, "ProjectItems") ->
          {:ok, %{status: 200, body: %{"data" => %{"node" => %{"items" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}}}
      end
    end

    assert {:ok, []} = Client.fetch_issues_by_states_for_test(["Todo"], user_settings, user_request)

    missing_status = fn query, _variables, _settings ->
      if String.contains?(query, "ProjectFields") do
        {:ok, %{status: 200, body: put_in(fields_body(), ["data", "node", "fields", "nodes"], [])}}
      else
        {:ok, %{status: 200, body: %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1"}}}}}}
      end
    end

    assert {:error, :github_projects_missing_status_field} =
             fetch_states(missing_status)

    malformed_field = fn query, _variables, _settings ->
      if String.contains?(query, "ProjectFields") do
        body = put_in(fields_body(), ["data", "node", "fields", "nodes"], [%{"__typename" => "ProjectV2SingleSelectField", "id" => 10, "name" => "Status"}])
        {:ok, %{status: 200, body: body}}
      else
        {:ok, %{status: 200, body: %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1"}}}}}}
      end
    end

    assert {:error, :github_projects_malformed_status_field} =
             fetch_states(malformed_field)

    malformed_fields_payload = fn query, _variables, _settings ->
      if String.contains?(query, "ProjectFields") do
        {:ok, %{status: 200, body: %{"data" => %{"node" => %{"fields" => nil}}}}}
      else
        {:ok, %{status: 200, body: %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1"}}}}}}
      end
    end

    assert {:error, :github_projects_unknown_payload} =
             fetch_states(malformed_fields_payload)
  end

  test "fails closed for malformed item pages and refresh responses" do
    project = %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1", "number" => 9}}}}

    malformed_items = fn query, _variables, _settings ->
      cond do
        String.contains?(query, "SymphonyGitHubProject(") -> {:ok, %{status: 200, body: project}}
        String.contains?(query, "ProjectFields") -> {:ok, %{status: 200, body: fields_body()}}
        String.contains?(query, "ProjectItems") -> {:ok, %{status: 200, body: %{"data" => %{"node" => %{"items" => nil}}}}}
      end
    end

    assert {:error, :github_projects_unknown_payload} =
             fetch_states(malformed_items)

    missing_item_cursor = fn query, _variables, _settings ->
      cond do
        String.contains?(query, "SymphonyGitHubProject(") ->
          {:ok, %{status: 200, body: project}}

        String.contains?(query, "ProjectFields") ->
          {:ok, %{status: 200, body: fields_body()}}

        String.contains?(query, "ProjectItems") ->
          body = put_in(item_body(nil), ["data", "node", "items", "pageInfo"], %{"hasNextPage" => true})
          {:ok, %{status: 200, body: body}}
      end
    end

    assert {:error, :github_projects_missing_end_cursor} =
             fetch_states(missing_item_cursor)

    malformed_item_node = fn query, _variables, _settings ->
      cond do
        String.contains?(query, "SymphonyGitHubProject(") ->
          {:ok, %{status: 200, body: project}}

        String.contains?(query, "ProjectFields") ->
          {:ok, %{status: 200, body: fields_body()}}

        String.contains?(query, "ProjectItems") ->
          body =
            item_body(nil)
            |> put_in(["data", "node", "items", "nodes"], ["bad"])
            |> put_in(["data", "node", "items", "pageInfo"], %{"hasNextPage" => false, "endCursor" => nil})

          {:ok, %{status: 200, body: body}}
      end
    end

    assert {:error, :github_projects_malformed_item} =
             fetch_states(malformed_item_node)

    malformed_nodes = fn query, _variables, _settings ->
      cond do
        String.contains?(query, "SymphonyGitHubProject(") -> {:ok, %{status: 200, body: project}}
        String.contains?(query, "ProjectFields") -> {:ok, %{status: 200, body: fields_body()}}
        String.contains?(query, "ProjectItemsById") -> {:ok, %{status: 200, body: %{"data" => %{"nodes" => nil}}}}
      end
    end

    assert {:error, :github_projects_unknown_payload} =
             Client.fetch_issues_by_ids_for_test(["PVTI_1"], tracker_settings(), malformed_nodes)

    request_error = fn query, _variables, _settings ->
      cond do
        String.contains?(query, "SymphonyGitHubProject(") -> {:ok, %{status: 200, body: project}}
        String.contains?(query, "ProjectFields") -> {:ok, %{status: 200, body: fields_body()}}
        String.contains?(query, "ProjectItemsById") -> {:error, :transport_down}
      end
    end

    assert {:error, {:github_projects_api_request, :transport_down}} =
             Client.fetch_issues_by_ids_for_test(["PVTI_1"], tracker_settings(), request_error)
  end

  test "fails closed for blocker and label hydration shapes" do
    project = %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1", "number" => 9}}}}
    fields = fields_body()

    run = fn item, extra ->
      fn query, variables, _settings ->
        cond do
          String.contains?(query, "SymphonyGitHubProject(") ->
            {:ok, %{status: 200, body: project}}

          String.contains?(query, "ProjectFields") ->
            {:ok, %{status: 200, body: fields}}

          String.contains?(query, "IssueBlockers") ->
            extra.(query, variables)

          String.contains?(query, "IssueLabels") ->
            extra.(query, variables)

          String.contains?(query, "ProjectItems") ->
            {:ok, %{status: 200, body: %{"data" => %{"node" => %{"items" => %{"nodes" => [item], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}}}
        end
      end
    end

    no_blockers = put_in(item(1, "one", false), ["content", "blockedBy"], nil)

    assert {:error, :github_projects_malformed_blockers} =
             fetch_states(run.(no_blockers, fn _, _ -> :never end))

    missing_blocker_cursor = put_in(item(1, "one", false), ["content", "blockedBy", "pageInfo"], %{"hasNextPage" => true})

    assert {:error, :github_projects_missing_end_cursor} =
             fetch_states(run.(missing_blocker_cursor, fn _, _ -> :never end))

    blocker_missing_issue_id = put_in(item(1, "one", true), ["content", "id"], nil)

    assert {:error, :github_projects_malformed_blockers} =
             fetch_states(run.(blocker_missing_issue_id, fn _, _ -> :never end))

    blocker_request_error = put_in(item(1, "one", true), ["content", "blockedBy", "pageInfo"], %{"hasNextPage" => true, "endCursor" => "next"})

    blocker_down = fn _query, _ -> {:error, :blocker_down} end

    assert {:error, :github_projects_malformed_blockers} =
             fetch_states(run.(blocker_request_error, blocker_down))

    blocker_bad_body = put_in(item(1, "one", true), ["content", "blockedBy", "pageInfo"], %{"hasNextPage" => true, "endCursor" => "next"})

    blocker_bad_response = fn query, _ ->
      if String.contains?(query, "IssueBlockers") do
        {:ok, %{status: 200, body: %{"data" => %{"node" => %{}}}}}
      else
        :never
      end
    end

    assert {:error, :github_projects_malformed_blockers} =
             fetch_states(run.(blocker_bad_body, blocker_bad_response))

    labels_without_page_info = put_in(item(1, "one", false), ["content", "labels"], %{"nodes" => []})

    assert {:ok, [_]} =
             fetch_states(run.(labels_without_page_info, fn _, _ -> :never end))

    labels_missing = put_in(item(1, "one", false), ["content", "labels"], nil)

    assert {:error, :github_projects_malformed_labels} =
             fetch_states(run.(labels_missing, fn _, _ -> :never end))

    labels_wrong_shape = put_in(item(1, "one", false), ["content", "labels"], %{"unexpected" => []})

    assert {:error, :github_projects_malformed_labels} =
             fetch_states(run.(labels_wrong_shape, fn _, _ -> :never end))

    labels_missing_cursor = put_in(item(1, "one", false), ["content", "labels", "pageInfo"], %{"hasNextPage" => true})

    assert {:error, :github_projects_missing_end_cursor} =
             fetch_states(run.(labels_missing_cursor, fn _, _ -> :never end))

    labels_missing_issue_id =
      item(1, "one", false)
      |> put_in(["content", "labels", "pageInfo"], %{"hasNextPage" => true, "endCursor" => "next"})
      |> put_in(["content", "id"], nil)

    assert {:error, :github_projects_malformed_labels} =
             fetch_states(run.(labels_missing_issue_id, fn _, _ -> :never end))

    labels_request_error = put_in(item(1, "one", false), ["content", "labels", "pageInfo"], %{"hasNextPage" => true, "endCursor" => "next"})

    labels_down = fn _query, _ -> {:error, :labels_down} end

    assert {:error, :github_projects_malformed_labels} =
             fetch_states(run.(labels_request_error, labels_down))

    labels_bad_body = put_in(item(1, "one", false), ["content", "labels", "pageInfo"], %{"hasNextPage" => true, "endCursor" => "next"})

    labels_bad_response = fn query, _ ->
      if String.contains?(query, "IssueLabels") do
        {:ok, %{status: 200, body: %{"data" => %{"node" => %{}}}}}
      else
        :never
      end
    end

    assert {:error, :github_projects_malformed_labels} =
             fetch_states(run.(labels_bad_body, labels_bad_response))
  end

  test "hydrates paginated blockers and labels and handles pagination errors" do
    project = %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1", "number" => 9}}}}
    paged_item = item(1, "one", true)
    paged_item = put_in(paged_item, ["content", "labels", "pageInfo"], %{"hasNextPage" => true, "endCursor" => "label-1"})

    request_fun = fn query, variables, _settings ->
      cond do
        String.contains?(query, "SymphonyGitHubProject(") ->
          {:ok, %{status: 200, body: project}}

        String.contains?(query, "ProjectFields") ->
          {:ok, %{status: 200, body: fields_body()}}

        String.contains?(query, "ProjectItems") ->
          {:ok, %{status: 200, body: %{"data" => %{"node" => %{"items" => %{"nodes" => [paged_item], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}}}

        String.contains?(query, "IssueBlockers") ->
          send(self(), {:blocker_after, variables["after"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "node" => %{
                   "blockedBy" => %{
                     "nodes" => [%{"id" => "I_closed", "number" => 4, "state" => "CLOSED", "repository" => repository("octo", "closed")}],
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                   }
                 }
               }
             }
           }}

        String.contains?(query, "IssueLabels") ->
          send(self(), {:labels_after, variables["after"]})
          {:ok, %{status: 200, body: %{"data" => %{"node" => %{"labels" => labels_body()}}}}}
      end
    end

    assert {:ok, [issue]} = fetch_states(request_fun)
    assert issue.labels == ["extra"]
    assert Enum.map(issue.blocked_by, & &1["identifier"]) == ["octo/blocker#3", "octo/closed#4"]
    assert_receive {:blocker_after, "blocker-1"}
    assert_receive {:labels_after, "label-1"}

    bad_blocker_page = fn query, _variables, _settings ->
      cond do
        String.contains?(query, "SymphonyGitHubProject(") ->
          {:ok, %{status: 200, body: project}}

        String.contains?(query, "ProjectFields") ->
          {:ok, %{status: 200, body: fields_body()}}

        String.contains?(query, "ProjectItems") ->
          body = put_in(paged_item, ["content", "blockedBy", "pageInfo"], %{"hasNextPage" => true, "endCursor" => "blocker-1"})
          {:ok, %{status: 200, body: %{"data" => %{"node" => %{"items" => %{"nodes" => [body], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}}}

        String.contains?(query, "IssueBlockers") ->
          {:ok, %{status: 200, body: %{"data" => %{"node" => %{"blockedBy" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true}}}}}}}
      end
    end

    assert {:error, :github_projects_malformed_blockers} =
             fetch_states(bad_blocker_page)

    bad_label_page = fn query, _variables, _settings ->
      cond do
        String.contains?(query, "SymphonyGitHubProject(") ->
          {:ok, %{status: 200, body: project}}

        String.contains?(query, "ProjectFields") ->
          {:ok, %{status: 200, body: fields_body()}}

        String.contains?(query, "ProjectItems") ->
          body = put_in(paged_item, ["content", "labels", "pageInfo"], %{"hasNextPage" => true, "endCursor" => "label-1"})
          {:ok, %{status: 200, body: %{"data" => %{"node" => %{"items" => %{"nodes" => [body], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}}}

        String.contains?(query, "IssueBlockers") ->
          {:ok, %{status: 200, body: blocker_body()}}

        String.contains?(query, "IssueLabels") ->
          {:ok, %{status: 200, body: %{"data" => %{"node" => %{"labels" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true}}}}}}}
      end
    end

    assert {:error, :github_projects_malformed_labels} =
             fetch_states(bad_label_page)
  end

  test "drops malformed candidate items and rejects malformed refresh items" do
    project = %{"data" => %{"organization" => %{"projectV2" => %{"id" => "PVT_1", "number" => 9}}}}

    candidate_request = fn query, _variables, _settings ->
      cond do
        String.contains?(query, "SymphonyGitHubProject(") ->
          {:ok, %{status: 200, body: project}}

        String.contains?(query, "ProjectFields") ->
          {:ok, %{status: 200, body: fields_body()}}

        String.contains?(query, "ProjectItems") ->
          malformed = Map.delete(item(1, "one", false), "id")
          {:ok, %{status: 200, body: %{"data" => %{"node" => %{"items" => %{"nodes" => [malformed], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}}}}
      end
    end

    assert {:ok, []} = fetch_states(candidate_request)

    refresh_request = fn query, _variables, _settings ->
      cond do
        String.contains?(query, "SymphonyGitHubProject(") ->
          {:ok, %{status: 200, body: project}}

        String.contains?(query, "ProjectFields") ->
          {:ok, %{status: 200, body: fields_body()}}

        String.contains?(query, "ProjectItemsById") ->
          malformed = Map.delete(item(1, "one", false), "id")
          {:ok, %{status: 200, body: %{"data" => %{"nodes" => [malformed]}}}}
      end
    end

    assert {:error, :github_projects_malformed_item_id} =
             Client.fetch_issues_by_ids_for_test(["PVTI_1"], tracker_settings(), refresh_request)
  end

  defp graphql_with(request_fun) do
    Client.graphql("query", %{}, tracker_settings: tracker_settings(), request_fun: request_fun)
  end

  defp fetch_states(request_fun) do
    Client.fetch_issues_by_states_for_test(["Todo"], tracker_settings(), request_fun)
  end

  defp labels_body do
    %{
      "nodes" => [%{"name" => " Extra "}],
      "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
    }
  end

  defp tracker_settings do
    %{
      kind: "github_projects",
      provider: %{
        "owner_type" => "org",
        "owner" => "octo",
        "project_number" => 9,
        "token" => "test-token"
      },
      active_states: ["Todo"],
      terminal_states: ["Done"]
    }
  end

  defp repository(owner, name) do
    %{
      "id" => "R_#{name}",
      "name" => name,
      "nameWithOwner" => "#{owner}/#{name}",
      "url" => "https://github.test/#{owner}/#{name}",
      "owner" => %{"login" => owner}
    }
  end

  defp fields_body do
    %{
      "data" => %{
        "node" => %{
          "fields" => %{
            "nodes" => [
              %{
                "__typename" => "ProjectV2SingleSelectField",
                "id" => "PVTF_status",
                "name" => "Status",
                "options" => [%{"id" => "opt-todo", "name" => "Todo"}]
              }
            ],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      }
    }
  end

  defp item_body(nil) do
    %{
      "data" => %{
        "node" => %{
          "items" => %{
            "nodes" => [item(1, "one", false), item(2, "two", true)],
            "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-1"}
          }
        }
      }
    }
  end

  defp item_body("cursor-1") do
    %{
      "data" => %{
        "node" => %{
          "items" => %{
            "nodes" => [],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      }
    }
  end

  defp item(number, repo, blockers?) do
    blocked_by =
      if blockers? do
        %{
          "nodes" => [%{"id" => "I_block", "number" => 3, "state" => "OPEN", "repository" => repository("octo", "blocker")}],
          "pageInfo" => %{"hasNextPage" => true, "endCursor" => "blocker-1"}
        }
      else
        %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
      end

    %{
      "id" => "PVTI_#{number}",
      "project" => %{"id" => "PVT_1"},
      "isArchived" => false,
      "fieldValueByName" => %{"name" => "Todo"},
      "content" => %{
        "__typename" => "Issue",
        "id" => "I_#{number}",
        "number" => number,
        "title" => "Issue #{number}",
        "state" => "OPEN",
        "url" => "https://github.test/octo/#{repo}/issues/#{number}",
        "repository" => repository("octo", repo),
        "labels" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}},
        "blockedBy" => blocked_by
      }
    }
  end

  defp blocker_body do
    %{
      "data" => %{
        "node" => %{
          "blockedBy" => %{
            "nodes" => [%{"id" => "I_closed", "number" => 4, "state" => "CLOSED", "repository" => repository("octo", "closed")}],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      }
    }
  end
end
