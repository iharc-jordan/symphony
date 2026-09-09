defmodule SymphonyElixir.GitHubProjects.Client do
  @moduledoc """
  GitHub Projects V2 GraphQL tracker adapter client.

  Project item node IDs are the scheduler identity. Underlying issue data stays
  in native_ref so a project can safely contain multiple repositories.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @graphql_url "https://api.github.com/graphql"
  @page_size 100
  @api_version "2022-11-28"

  @project_query """
  query SymphonyGitHubProject($owner: String!, $projectNumber: Int!) {
    organization(login: $owner) { projectV2(number: $projectNumber) { id number } }
  }
  """

  @user_project_query """
  query SymphonyGitHubUserProject($owner: String!, $projectNumber: Int!) {
    user(login: $owner) { projectV2(number: $projectNumber) { id number } }
  }
  """

  @fields_query """
  query SymphonyGitHubProjectFields($projectId: ID!, $first: Int!, $after: String) {
    node(id: $projectId) {
      ... on ProjectV2 {
        fields(first: $first, after: $after) {
          nodes {
            __typename
            ... on ProjectV2SingleSelectField {
              id
              name
              options { id name }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @item_fields """
  id
  isArchived
  project { id }
  fieldValueByName(name: $statusFieldName) {
    __typename
    ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
  }
  content {
    __typename
    ... on Issue {
      id number title body state stateReason url
      repository { id name nameWithOwner url owner { login } }
      assignees(first: 1) { nodes { id login } }
      labels(first: 100) { nodes { name } pageInfo { hasNextPage endCursor } }
      blockedBy(first: $blockerFirst) {
        nodes {
          id number state
          repository { id name nameWithOwner url owner { login } }
        }
        pageInfo { hasNextPage endCursor }
      }
      createdAt updatedAt
    }
    ... on PullRequest {
      id number title body state stateReason url
      repository { id name nameWithOwner url owner { login } }
      labels(first: 100) { nodes { name } pageInfo { hasNextPage endCursor } }
      createdAt updatedAt
    }
    ... on DraftIssue { id title body }
  }
  """

  @items_query """
  query SymphonyGitHubProjectItems($projectId: ID!, $statusFieldName: String!, $first: Int!, $blockerFirst: Int!, $after: String) {
    node(id: $projectId) {
      ... on ProjectV2 {
        items(first: $first, after: $after, archivedStates: NOT_ARCHIVED) {
          nodes {
            #{@item_fields}
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @items_by_id_query """
  query SymphonyGitHubProjectItemsById($itemIds: [ID!]!, $statusFieldName: String!, $blockerFirst: Int!) {
    nodes(ids: $itemIds) {
      ... on ProjectV2Item {
        #{@item_fields}
      }
    }
  }
  """

  @blockers_query """
  query SymphonyGitHubIssueBlockers($issueId: ID!, $first: Int!, $after: String) {
    node(id: $issueId) {
      ... on Issue {
        blockedBy(first: $first, after: $after) {
          nodes {
            id number state
            repository { id name nameWithOwner url owner { login } }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @labels_query """
  query SymphonyGitHubIssueLabels($issueId: ID!, $first: Int!, $after: String) {
    node(id: $issueId) {
      ... on Issue {
        labels(first: $first, after: $after) {
          nodes { name }
          pageInfo { hasNextPage endCursor }
        }
      }
      ... on PullRequest {
        labels(first: $first, after: $after) {
          nodes { name }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """
  @typep cursor_seen :: map()

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    [
      "GITHUB_TOKEN",
      "GH_TOKEN",
      "GITHUB_ENTERPRISE_TOKEN",
      "GH_ENTERPRISE_TOKEN" | env_reference_names([provider["token"]])
    ]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    fetch_issues_by_states(states, Config.settings!().tracker, &perform_request/2)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids) when is_list(ids) do
    fetch_issues_by_ids(ids, Config.settings!().tracker, &perform_request/2)
  end

  @doc """
  Fetch the project identity and status field configured for the tracker.

  The result is the service-owned binding shape used by managed controls. It
  is intentionally read from WORKFLOW.md and GitHub, never from a control
  request.
  """
  @spec fetch_configured_binding(keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_configured_binding(opts \\ []) when is_list(opts) do
    tracker = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/2)

    with {:ok, settings} <- settings(tracker),
         {:ok, project} <- fetch_project(settings, request_fun),
         {:ok, status_field} <- fetch_status_field(settings, project.id, request_fun) do
      status_options =
        Enum.reduce(status_field.options, %{}, fn {option_id, option_name}, acc ->
          Map.put(acc, option_name, option_id)
        end)

      {:ok,
       %{
         project_id: project.id,
         project_number: project.number,
         status_field_id: status_field.id,
         status_options: status_options
       }}
    end
  rescue
    error -> {:error, {:github_projects_binding_fetch_failed, Exception.message(error)}}
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    tracker = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/2)

    with {:ok, settings} <- settings(tracker) do
      call_graphql(query, variables, settings, request_fun)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), map()) :: Issue.t() | nil
  def normalize_issue_for_test(item, tracker_settings) when is_map(item) and is_map(tracker_settings) do
    item = Map.put_new(item, "project", %{"id" => "test-project"})

    with {:ok, _settings} <- settings(tracker_settings),
         project_id <- get_in(item, ["project", "id"]),
         status <- item_status(item, %{}),
         {:ok, issue} <- normalize_item(item, project_id, status) do
      issue
    else
      _ -> nil
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(states, tracker_settings, request_fun)
      when is_list(states) and is_map(tracker_settings) and is_function(request_fun) do
    fetch_issues_by_states(states, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(ids, tracker_settings, request_fun)
      when is_list(ids) and is_map(tracker_settings) and is_function(request_fun) do
    fetch_issues_by_ids(ids, tracker_settings, request_fun)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  defp fetch_issues_by_states(states, tracker, request_fun) do
    requested = states |> Enum.map(&normalize_state/1) |> Enum.reject(&(&1 == "")) |> MapSet.new()

    if MapSet.size(requested) == 0 do
      {:ok, []}
    else
      with {:ok, settings} <- settings(tracker),
           {:ok, project} <- fetch_project(settings, request_fun),
           {:ok, status_field} <- fetch_status_field(settings, project.id, request_fun),
           {:ok, raw_items} <- fetch_items(settings, project.id, status_field, request_fun),
           {:ok, items} <- hydrate_items(raw_items, settings, request_fun),
           {:ok, issues} <- normalize_items(items, project.id, status_field, :candidate) do
        {:ok, Enum.filter(issues, &MapSet.member?(requested, normalize_state(&1.state)))}
      end
    end
  end

  defp fetch_issues_by_ids(ids, tracker, request_fun) do
    ids = ids |> Enum.filter(&present_string?/1) |> Enum.uniq()

    if ids == [] do
      {:ok, []}
    else
      with {:ok, settings} <- settings(tracker),
           {:ok, project} <- fetch_project(settings, request_fun),
           {:ok, status_field} <- fetch_status_field(settings, project.id, request_fun),
           {:ok, raw_items} <-
             fetch_items_by_ids(settings, status_field, ids, request_fun),
           {:ok, items} <- hydrate_items(raw_items, settings, request_fun),
           {:ok, issues} <- normalize_items(items, project.id, status_field, :refresh) do
        by_id = Map.new(issues, &{&1.id, &1})
        {:ok, Enum.flat_map(ids, fn id -> if by_id[id], do: [by_id[id]], else: [] end)}
      end
    end
  end

  defp fetch_project(settings, request_fun) do
    variables = %{"owner" => settings.owner, "projectNumber" => settings.project_number}

    query = if(settings.owner_type == "org", do: @project_query, else: @user_project_query)

    with {:ok, body} <- call_graphql(query, variables, settings, request_fun),
         %{"data" => data} <- body,
         %{} = owner <- Map.get(data, if(settings.owner_type == "org", do: "organization", else: "user")),
         %{"id" => id} = project when is_binary(id) <- Map.get(owner, "projectV2") do
      {:ok, %{id: id, number: project["number"]}}
    else
      nil -> {:error, :github_projects_project_not_found}
      _ -> {:error, :github_projects_malformed_project}
    end
  end

  defp fetch_status_field(settings, project_id, request_fun) do
    fetch_status_fields(settings, project_id, nil, [], request_fun, %{})
  end

  @spec fetch_status_fields(map(), String.t(), nil | String.t(), list(), function(), cursor_seen()) ::
          {:ok, term()} | {:error, term()}
  # credo:disable-for-next-line
  defp fetch_status_fields(settings, project_id, after_cursor, acc, request_fun, seen) do
    with {:ok, seen} <- validate_cursor(after_cursor, seen),
         variables <- %{"projectId" => project_id, "first" => @page_size, "after" => after_cursor},
         {:ok, body} <- call_graphql(@fields_query, variables, settings, request_fun),
         {:ok, fields, page_info} <- fields_from_body(body) do
      matching =
        Enum.filter(fields, fn
          %{"__typename" => "ProjectV2SingleSelectField", "name" => name} ->
            normalize_state(name) == normalize_state(settings.status_field_name)

          _ ->
            false
        end)

      case next_page_cursor(page_info) do
        {:ok, cursor} ->
          fetch_status_fields(
            settings,
            project_id,
            cursor,
            matching ++ acc,
            request_fun,
            seen
          )

        :done ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case Enum.reverse(matching ++ acc) do
            [field | _] -> parse_status_field(field)
            [] -> {:error, :github_projects_missing_status_field}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fields_from_body(%{"data" => %{"node" => %{"fields" => fields}}}) when is_map(fields) do
    with {:ok, nodes} <- required_nodes(fields), {:ok, page_info} <- required_page_info(fields) do
      {:ok, nodes, page_info}
    end
  end

  defp fields_from_body(_), do: {:error, :github_projects_unknown_payload}

  defp parse_status_field(%{"id" => id, "name" => name} = field)
       when is_binary(id) and is_binary(name) do
    options =
      field
      |> option_nodes()
      |> Enum.reduce(%{}, fn
        %{"id" => option_id, "name" => option_name}, acc
        when is_binary(option_id) and is_binary(option_name) ->
          Map.put(acc, option_id, option_name)

        _, acc ->
          acc
      end)

    {:ok, %{id: id, name: name, options: options}}
  end

  defp parse_status_field(_), do: {:error, :github_projects_malformed_status_field}

  defp option_nodes(%{"options" => options}), do: option_nodes(options)
  defp option_nodes(%{"nodes" => nodes}) when is_list(nodes), do: nodes
  defp option_nodes(options) when is_list(options), do: options
  defp option_nodes(_), do: []

  defp fetch_items(settings, project_id, field, request_fun) do
    fetch_item_pages(settings, project_id, field, nil, [], request_fun, %{})
  end

  @spec fetch_item_pages(map(), String.t(), map(), nil | String.t(), list(), function(), cursor_seen()) ::
          {:ok, term()} | {:error, term()}
  defp fetch_item_pages(settings, project_id, field, after_cursor, acc, request_fun, seen) do
    with {:ok, seen} <- validate_cursor(after_cursor, seen),
         variables <- %{
           "projectId" => project_id,
           "statusFieldName" => field.name,
           "first" => @page_size,
           "blockerFirst" => @page_size,
           "after" => after_cursor
         },
         {:ok, body} <- call_graphql(@items_query, variables, settings, request_fun),
         {:ok, nodes, page_info} <- items_from_body(body) do
      case next_page_cursor(page_info) do
        {:ok, cursor} ->
          fetch_item_pages(
            settings,
            project_id,
            field,
            cursor,
            acc ++ nodes,
            request_fun,
            seen
          )

        :done ->
          {:ok, acc ++ nodes}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # credo:disable-for-next-line
  defp fetch_items_by_ids(settings, field, ids, request_fun) do
    Enum.reduce_while(Enum.chunk_every(ids, @page_size), {:ok, []}, fn batch, {:ok, acc} ->
      variables = %{
        "itemIds" => batch,
        "statusFieldName" => field.name,
        "blockerFirst" => @page_size
      }

      case call_graphql(@items_by_id_query, variables, settings, request_fun) do
        {:ok, body} ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case nodes_from_body(body) do
            {:ok, nodes} -> {:cont, {:ok, nodes ++ acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp hydrate_items(items, settings, request_fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case hydrate_item(item, settings, request_fun) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hydrate_item(item, settings, request_fun) when is_map(item) do
    with {:ok, item} <- hydrate_blockers(item, settings, request_fun) do
      hydrate_labels(item, settings, request_fun)
    end
  end

  defp hydrate_item(_item, _settings, _request_fun),
    do: {:error, :github_projects_malformed_item}

  defp hydrate_blockers(item, settings, request_fun) do
    if content_type(item["content"]) == "Issue" do
      hydrate_issue_blockers(item, settings, request_fun)
    else
      {:ok, item}
    end
  end

  defp hydrate_issue_blockers(item, settings, request_fun) do
    case Map.fetch(item["content"] || %{}, "blockedBy") do
      {:ok, %{"nodes" => nodes, "pageInfo" => page_info}} when is_list(nodes) and is_map(page_info) ->
        hydrate_blocker_page(item, nodes, page_info, settings, request_fun)

      _ ->
        {:error, :github_projects_malformed_blockers}
    end
  end

  defp hydrate_blocker_page(item, nodes, page_info, settings, request_fun) do
    case next_page_cursor(page_info) do
      :done ->
        {:ok, item}

      {:error, reason} ->
        {:error, reason}

      {:ok, cursor} ->
        with issue_id when is_binary(issue_id) <- get_in(item, ["content", "id"]),
             {:ok, more} <- fetch_blocker_pages(settings, issue_id, cursor, request_fun, []) do
          {:ok, put_in(item, ["content", "blockedBy", "nodes"], nodes ++ more)}
        else
          _ -> {:error, :github_projects_malformed_blockers}
        end
    end
  end

  defp hydrate_labels(item, settings, request_fun) do
    if content_type(item["content"]) == "Issue" do
      hydrate_issue_labels(item, settings, request_fun)
    else
      {:ok, item}
    end
  end

  defp hydrate_issue_labels(item, settings, request_fun) do
    case get_in(item, ["content", "labels"]) do
      %{"nodes" => nodes, "pageInfo" => page_info} when is_list(nodes) and is_map(page_info) ->
        hydrate_label_page(item, nodes, page_info, settings, request_fun)

      %{"nodes" => _nodes} ->
        {:ok, item}

      nil ->
        {:error, :github_projects_malformed_labels}

      _ ->
        {:error, :github_projects_malformed_labels}
    end
  end

  defp hydrate_label_page(item, nodes, page_info, settings, request_fun) do
    case next_page_cursor(page_info) do
      :done ->
        {:ok, item}

      {:error, reason} ->
        {:error, reason}

      {:ok, cursor} ->
        with issue_id when is_binary(issue_id) <- get_in(item, ["content", "id"]),
             {:ok, more} <- fetch_label_pages(settings, issue_id, cursor, request_fun, []) do
          {:ok, put_in(item, ["content", "labels", "nodes"], nodes ++ more)}
        else
          _ -> {:error, :github_projects_malformed_labels}
        end
    end
  end

  defp fetch_blocker_pages(settings, issue_id, after_cursor, request_fun, acc) do
    fetch_blocker_pages(settings, issue_id, after_cursor, request_fun, acc, %{})
  end

  @spec fetch_blocker_pages(map(), String.t(), String.t(), function(), list(), cursor_seen()) ::
          {:ok, term()} | {:error, term()}
  defp fetch_blocker_pages(settings, issue_id, after_cursor, request_fun, acc, seen) do
    with {:ok, seen} <- validate_cursor(after_cursor, seen),
         variables <- %{"issueId" => issue_id, "first" => @page_size, "after" => after_cursor},
         {:ok, body} <- call_graphql(@blockers_query, variables, settings, request_fun),
         {:ok, nodes, page_info} <- blockers_from_body(body) do
      case next_page_cursor(page_info) do
        {:ok, cursor} ->
          fetch_blocker_pages(
            settings,
            issue_id,
            cursor,
            request_fun,
            nodes ++ acc,
            seen
          )

        :done ->
          {:ok, acc ++ nodes}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_label_pages(settings, issue_id, after_cursor, request_fun, acc) do
    fetch_label_pages(settings, issue_id, after_cursor, request_fun, acc, %{})
  end

  @spec fetch_label_pages(map(), String.t(), String.t(), function(), list(), cursor_seen()) ::
          {:ok, term()} | {:error, term()}
  defp fetch_label_pages(settings, issue_id, after_cursor, request_fun, acc, seen) do
    with {:ok, seen} <- validate_cursor(after_cursor, seen),
         variables <- %{"issueId" => issue_id, "first" => @page_size, "after" => after_cursor},
         {:ok, body} <- call_graphql(@labels_query, variables, settings, request_fun),
         {:ok, nodes, page_info} <- labels_from_body(body) do
      case next_page_cursor(page_info) do
        {:ok, cursor} ->
          fetch_label_pages(
            settings,
            issue_id,
            cursor,
            request_fun,
            nodes ++ acc,
            seen
          )

        :done ->
          {:ok, acc ++ nodes}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp labels_from_body(%{"data" => %{"node" => %{"labels" => labels}}}) when is_map(labels) do
    with {:ok, nodes} <- required_nodes(labels), {:ok, page_info} <- required_page_info(labels) do
      {:ok, nodes, page_info}
    end
  end

  defp labels_from_body(_), do: {:error, :github_projects_unknown_payload}

  defp blockers_from_body(%{"data" => %{"node" => %{"blockedBy" => blockers}}}) when is_map(blockers) do
    with {:ok, nodes} <- required_nodes(blockers), {:ok, page_info} <- required_page_info(blockers) do
      {:ok, nodes, page_info}
    end
  end

  defp blockers_from_body(_), do: {:error, :github_projects_unknown_payload}

  defp normalize_items(items, project_id, field, mode) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      status = item_status(item, field.options)

      case normalize_item(item, project_id, status) do
        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, issue} ->
          {:cont, {:ok, [issue | acc]}}

        {:error, reason} when mode == :candidate ->
          Logger.warning("Dropping malformed GitHub Projects item reason=#{inspect(reason)}")
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_item(item, project_id, status) when is_map(item) do
    item_id = item["id"]
    content = item["content"]
    type = content_type(content)

    project_ref = get_in(item, ["project", "id"])

    cond do
      not present_string?(item_id) -> {:error, :github_projects_malformed_item_id}
      item["isArchived"] == true -> {:ok, nil}
      not present_string?(project_ref) -> {:error, :github_projects_missing_project_membership}
      project_ref != project_id -> {:ok, nil}
      not present_string?(status) -> {:error, :github_projects_missing_item_status}
      type == "DraftIssue" -> {:error, :github_projects_unsupported_draft_issue}
      type not in ["Issue", "PullRequest"] -> {:error, :github_projects_missing_content}
      true -> normalize_content(content, project_id, item_id, type, String.trim(status))
    end
  end

  defp normalize_item(_, _, _), do: {:error, :github_projects_malformed_item}

  defp normalize_content(content, project_id, item_id, type, status) when is_map(content) do
    issue_id = content["id"]
    number = content["number"]
    title = content["title"]
    repository = repository_ref(content["repository"])
    blockers = extract_blockers(content)

    cond do
      not present_string?(issue_id) ->
        {:error, :github_projects_missing_issue_id}

      not (is_integer(number) and number > 0) ->
        {:error, :github_projects_missing_issue_number}

      not present_string?(title) ->
        {:error, :github_projects_missing_title}

      is_nil(repository) ->
        {:error, :github_projects_missing_repository}

      true ->
        {:ok,
         %Issue{
           id: item_id,
           native_ref: %{
             "project_id" => project_id,
             "project_item_id" => item_id,
             "issue_id" => issue_id,
             "repository" => repository,
             "issue_number" => number,
             "content_type" => type,
             "issue_state" => content["state"],
             "issue_state_reason" => content["stateReason"]
           },
           identifier: repository["name_with_owner"] <> "#" <> Integer.to_string(number),
           title: title,
           description: content["body"],
           state: status,
           url: content["url"],
           assignee_id: assignee_id(content),
           labels: extract_labels(content),
           blocked_by: blockers,
           dispatchable:
             type == "Issue" and normalize_state(content["state"]) == "open" and
               Enum.all?(blockers, &terminal_blocker?/1),
           created_at: parse_datetime(content["createdAt"]),
           updated_at: parse_datetime(content["updatedAt"])
         }}
    end
  end

  defp normalize_content(_, _, _, _, _), do: {:error, :github_projects_missing_content}

  defp content_type(%{"__typename" => type}) when is_binary(type), do: type
  defp content_type(%{"type" => type}) when is_binary(type), do: type
  defp content_type(_), do: nil

  # credo:disable-for-next-line
  defp item_status(item, options) when is_map(item) and is_map(options) do
    value = item["fieldValueByName"] || item["status"] || item["field_value"]

    case value do
      %{"optionId" => id} -> Map.get(options, id)
      %{"option_id" => id} -> Map.get(options, id)
      %{"name" => name} when is_binary(name) -> if present_string?(name), do: String.trim(name)
      name when is_binary(name) -> if present_string?(name), do: String.trim(name)
      _ -> nil
    end
  end

  # credo:disable-for-next-line
  defp item_status(_, _), do: nil

  defp extract_blockers(%{"blockedBy" => %{"nodes" => nodes}}) when is_list(nodes) do
    Enum.map(nodes, &normalize_blocker/1)
  end

  defp extract_blockers(_), do: []

  defp normalize_blocker(blocker) when is_map(blocker) do
    repository = repository_ref(blocker["repository"])
    number = blocker["number"]

    identifier =
      if repository && is_integer(number) do
        repository["name_with_owner"] <> "#" <> Integer.to_string(number)
      end

    %{
      "id" => blocker["id"],
      "identifier" => identifier,
      "state" => blocker_state(blocker["state"])
    }
  end

  defp normalize_blocker(_), do: %{"id" => nil, "identifier" => nil, "state" => nil}

  defp blocker_state(%{"name" => name}) when is_binary(name), do: String.trim(name)
  defp blocker_state(state) when is_binary(state), do: String.trim(state)
  defp blocker_state(_), do: nil

  defp terminal_blocker?(%{"state" => state}) when is_binary(state), do: normalize_state(state) == "closed"
  defp terminal_blocker?(_), do: false

  defp repository_ref(repository) when is_map(repository) do
    owner = get_in(repository, ["owner", "login"])
    name = repository["name"]
    name_with_owner = repository["nameWithOwner"] || repository["name_with_owner"]

    if Enum.all?([owner, name, name_with_owner], &present_string?/1) do
      %{
        "owner" => owner,
        "name" => name,
        "name_with_owner" => name_with_owner,
        "id" => repository["id"],
        "url" => repository["url"]
      }
    end
  end

  defp repository_ref(_), do: nil

  defp assignee_id(%{"assignees" => %{"nodes" => [assignee | _]}}), do: assignee_id(assignee)
  defp assignee_id(%{"id" => id}) when is_binary(id), do: id
  defp assignee_id(%{"id" => id}) when is_integer(id), do: Integer.to_string(id)
  defp assignee_id(%{"login" => login}) when is_binary(login), do: login
  defp assignee_id(_), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}), do: normalize_labels(labels)
  defp extract_labels(%{"labels" => labels}) when is_list(labels), do: normalize_labels(labels)
  defp extract_labels(_), do: []

  defp normalize_labels(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp items_from_body(%{"data" => %{"node" => %{"items" => items}}}) when is_map(items) do
    with {:ok, nodes} <- required_nodes(items), {:ok, page_info} <- required_page_info(items) do
      {:ok, nodes, page_info}
    end
  end

  defp items_from_body(_), do: {:error, :github_projects_unknown_payload}

  defp nodes_from_body(%{"data" => %{"nodes" => nodes}}) when is_list(nodes),
    do: {:ok, Enum.reject(nodes, &is_nil/1)}

  defp nodes_from_body(_), do: {:error, :github_projects_unknown_payload}

  defp required_nodes(%{"nodes" => nodes}) when is_list(nodes), do: {:ok, nodes}
  defp required_nodes(_), do: {:error, :github_projects_unknown_payload}

  defp required_page_info(%{"pageInfo" => page_info}) when is_map(page_info), do: {:ok, page_info}
  defp required_page_info(_), do: {:error, :github_projects_unknown_payload}

  defp next_page_cursor(%{"hasNextPage" => true, "endCursor" => cursor})
       when is_binary(cursor) and byte_size(cursor) > 0, do: {:ok, cursor}

  defp next_page_cursor(%{"hasNextPage" => true}),
    do: {:error, :github_projects_missing_end_cursor}

  defp next_page_cursor(%{"hasNextPage" => false}), do: :done

  defp next_page_cursor(_), do: {:error, :github_projects_malformed_page_info}

  @spec validate_cursor(nil | String.t(), cursor_seen()) ::
          {:ok, cursor_seen()} | {:error, atom()}
  defp validate_cursor(nil, seen), do: {:ok, seen}

  defp validate_cursor(cursor, seen) when is_binary(cursor) and is_map(seen) do
    if Map.has_key?(seen, cursor) do
      {:error, :github_projects_repeated_cursor}
    else
      {:ok, Map.put(seen, cursor, true)}
    end
  end

  # credo:disable-for-next-line
  defp call_graphql(query, variables, tracker, request_fun) when is_map(tracker) do
    payload = %{"query" => query, "variables" => variables}

    response =
      case :erlang.fun_info(request_fun, :arity) do
        {:arity, 3} -> request_fun.(query, variables, tracker)
        {:arity, 2} -> request_fun.(payload, tracker)
        {:arity, 1} -> request_fun.(payload)
        _ -> {:error, :github_projects_invalid_request_fun}
      end

    case response do
      {:ok, %{status: 200, body: body}} -> decode_body(body)
      {:ok, %{status: status}} when status in [403, 429] -> {:error, {:github_projects_rate_limited, status}}
      {:ok, %{status: status}} when is_integer(status) -> {:error, {:github_projects_api_status, status}}
      {:ok, body} when is_map(body) -> decode_body(body)
      {:error, reason} -> {:error, {:github_projects_api_request, reason}}
      _ -> {:error, :github_projects_unknown_payload}
    end
  end

  # credo:disable-for-next-line
  defp call_graphql(_, _, _, _), do: {:error, :github_projects_unknown_payload}

  defp decode_body(%{"errors" => errors}) when is_list(errors) and errors != [],
    do: {:error, {:github_projects_graphql_errors, errors}}

  defp decode_body(%{"data" => _} = body), do: {:ok, body}
  defp decode_body(_), do: {:error, :github_projects_unknown_payload}

  defp perform_request(payload, settings) do
    Req.post(settings.graphql_url,
      headers: [
        {"Accept", "application/vnd.github+json"},
        {"Authorization", "Bearer #{settings.token}"},
        {"X-GitHub-Api-Version", @api_version},
        {"User-Agent", "symphony"},
        {"Content-Type", "application/json"}
      ],
      json: payload,
      connect_options: [timeout: 30_000]
    )
    |> case do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # credo:disable-for-next-line
  defp settings(tracker) when is_map(tracker) do
    provider = provider_settings(tracker)
    owner_type = resolve_setting(provider["owner_type"], nil)
    owner = resolve_setting(provider["owner"], nil)
    project_number = provider["project_number"]
    status_field_name = resolve_setting(provider["status_field_name"], "Status")
    graphql_url = provider["graphql_url"] || @graphql_url
    token = resolve_setting(provider["token"], System.get_env("GITHUB_TOKEN"))

    cond do
      owner_type not in ["user", "org"] ->
        {:error, :invalid_github_projects_owner_type}

      not present_string?(owner) ->
        {:error, :missing_github_projects_owner}

      not (is_integer(project_number) and project_number > 0) ->
        {:error, :invalid_github_projects_project_number}

      not present_string?(status_field_name) ->
        {:error, :invalid_github_projects_status_field_name}

      not valid_api_url?(graphql_url) ->
        {:error, :invalid_github_projects_graphql_url}

      not present_string?(token) ->
        {:error, :missing_github_projects_token}

      true ->
        {:ok,
         %{
           graphql_url: String.trim_trailing(graphql_url, "/"),
           owner_type: owner_type,
           owner: owner,
           project_number: project_number,
           status_field_name: status_field_name,
           token: token
         }}
    end
  end

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env, fallback) do
    if valid_env_name?(env), do: normalize_string(System.get_env(env) || fallback), else: nil
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env when is_binary(env) -> if valid_env_name?(env), do: [env], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_api_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      _ -> false
    end
  end

  defp valid_api_url?(_), do: false

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_string(_), do: nil
  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_), do: ""
  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_), do: false

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
