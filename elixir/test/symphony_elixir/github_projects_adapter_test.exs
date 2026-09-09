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
