defmodule SymphonyElixir.Managed.GitHubEffects do
  @moduledoc """
  Service-owned GitHub Projects effects for managed controls.

  Every method verifies the current native item before mutating GitHub. The
  Orchestrator calls these methods from its serialized control path after the
  corresponding durable intent has been journaled.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHubProjects.Client

  @status_mutation """
  mutation SymphonyManagedSetProjectStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: {singleSelectOptionId: $optionId}
    }) {
      projectV2Item { id }
    }
  }
  """

  @close_issue_mutation """
  mutation SymphonyManagedCloseIssue($issueId: ID!) {
    closeIssue(input: {issueId: $issueId, stateReason: COMPLETED}) {
      issue { id state stateReason }
    }
  }
  """

  @type service_context :: %{optional(:binding) => map(), optional(:process_stopped) => boolean()}

  @doc """
  Apply the accepted review effects in order: verify, set board ACCEPTED,
  close the native issue, then refetch both provider states for reconciliation.
  """
  @spec review(map(), map(), service_context()) :: {:ok, map()} | {:error, atom(), map()}
  def review(assignment, _args, context \\ %{}) when is_map(assignment) and is_map(context) do
    with :ok <- provider_kind_ok(),
         :ok <- process_stopped(context),
         {:ok, before} <- fetch_exact_assignment(assignment),
         :ok <- verify_material(before, assignment),
         :ok <- native_issue_only(before),
         :ok <- ensure_project_accepted(before, context),
         {:ok, status_check} <- fetch_exact_assignment(assignment),
         :ok <- provider_status_is(status_check, :accepted),
         :ok <- close_native_item(status_check),
         {:ok, after_close} <- fetch_exact_assignment(assignment),
         :ok <- verify_material(after_close, assignment),
         :ok <- provider_status_is(after_close, :accepted),
         :ok <- native_state_is_closed(after_close) do
      {:ok,
       %{
         provider_state: :review,
         provider_final_state: :accepted,
         issue_final_state: :closed,
         reconciled: true,
         external_effects: %{status: :ok, issue_close: :ok},
         observed_issue_id: native_value(after_close, :issue_id),
         observed_project_item_id: native_value(after_close, :project_item_id)
       }}
    end
  end

  @doc "Apply a board status transition after the Orchestrator journals its intent."
  @spec transition(map(), atom(), service_context()) :: {:ok, map()} | {:error, atom(), map()}
  def transition(assignment, target, context \\ %{}) when is_map(assignment) and is_atom(target) do
    with :ok <- provider_kind_ok(),
         {:ok, issue} <- fetch_exact_assignment(assignment),
         :ok <- verify_material(issue, assignment),
         :ok <- native_issue_only(issue),
         :ok <- transition_process_precondition(context, target),
         :ok <- ensure_project_status(issue, context, target),
         {:ok, observed} <- fetch_exact_assignment(assignment),
         :ok <- verify_material(observed, assignment),
         :ok <- provider_status_is(observed, target) do
      {:ok, %{provider_state: target, reconciled: true, external_effects: %{status: :ok}}}
    end
  end

  defp transition_process_precondition(%{process_stopped: false}, target)
       when target in [:ready, :waiting, :cancelled],
       do: {:error, :managed_process_not_stopped, %{}}

  defp transition_process_precondition(_context, _target), do: :ok

  defp ensure_project_status(issue, context, target) do
    if provider_status(issue) == target do
      :ok
    else
      with {:ok, option} <- status_option(context, target),
           :ok <- set_project_status(issue, context, option) do
        :ok
      end
    end
  end

  defp ensure_project_accepted(issue, context) do
    case provider_status(issue) do
      :review ->
        with {:ok, accepted_option} <- status_option(context, :accepted),
             :ok <- set_project_status(issue, context, accepted_option) do
          :ok
        end

      :accepted ->
        :ok

      actual ->
        {:error, :managed_provider_state_mismatch, %{expected: :review, actual: actual}}
    end
  end

  defp provider_kind_ok do
    case Config.settings!().tracker.kind do
      "github_projects" -> :ok
      _ -> {:error, :managed_github_provider_required, %{}}
    end
  rescue
    _ -> {:error, :managed_github_provider_unavailable, %{}}
  end

  defp process_stopped(%{process_stopped: true}), do: :ok
  defp process_stopped(_), do: {:error, :managed_process_not_stopped, %{}}

  defp fetch_exact_assignment(assignment) do
    item_id = text(assignment, :assignment_id)

    with true <- is_binary(item_id),
         {:ok, [issue]} <- Client.fetch_issues_by_ids([item_id]),
         :ok <- exact_identity(issue, assignment) do
      {:ok, issue}
    else
      false -> {:error, :invalid_assignment_identity, %{}}
      {:ok, []} -> {:error, :managed_native_item_not_found, %{}}
      {:ok, _issues} -> {:error, :managed_native_item_ambiguous, %{}}
      {:error, reason} -> {:error, :managed_native_fetch_failed, %{reason: inspect(reason)}}
      _ -> {:error, :managed_native_item_malformed, %{}}
    end
  end

  defp exact_identity(issue, assignment) do
    repository = get_in(issue.native_ref || %{}, ["repository", "name_with_owner"])
    issue_number = get_in(issue.native_ref || %{}, ["issue_number"])
    project_item_id = native_value(issue, :project_item_id)
    expected_project_item_id = text(assignment, :project_item_id) || text(assignment, :assignment_id)

    if repository == text(assignment, :repository) and
         issue_number == Map.get(assignment, :issue_number) and
         (is_nil(expected_project_item_id) or project_item_id == expected_project_item_id) do
      :ok
    else
      {:error, :managed_native_identity_mismatch, %{}}
    end
  end

  defp native_issue_only(issue) do
    if native_value(issue, :content_type) == "Issue", do: :ok, else: {:error, :managed_native_issue_required, %{}}
  end

  defp verify_material(issue, assignment) do
    expected = text(assignment, :requirements_fingerprint)

    cond do
      is_nil(expected) -> {:error, :requirements_fingerprint_missing, %{}}
      not String.starts_with?(expected, "sha256:") -> {:error, :invalid_requirements_fingerprint, %{}}
      material_fingerprint(issue.description) == expected -> :ok
      true -> {:error, :requirements_changed, %{}}
    end
  end

  defp material_fingerprint(body) when is_binary(body), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  defp material_fingerprint(_body), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

  defp provider_status(issue) do
    case issue.state |> to_string() |> String.trim() |> String.downcase() do
      "ready" -> :ready
      "active" -> :active
      "review" -> :review
      "accepted" -> :accepted
      "waiting" -> :waiting
      "cancelled" -> :cancelled
      "canceled" -> :cancelled
      _ -> :unknown
    end
  end

  defp provider_status_is(issue, expected) do
    actual = provider_status(issue)
    if actual == expected, do: :ok, else: {:error, :managed_provider_state_mismatch, %{expected: expected, actual: actual}}
  end

  defp native_state_is_closed(issue) do
    state = native_value(issue, :issue_state) |> to_string() |> String.downcase()
    reason = native_value(issue, :issue_state_reason) |> to_string() |> String.downcase()

    cond do
      state != "closed" -> {:error, :managed_issue_not_closed, %{state: state}}
      reason != "completed" -> {:error, :managed_issue_closed_with_wrong_reason, %{reason: reason}}
      true -> :ok
    end
  end

  defp close_native_item(issue) do
    id = native_value(issue, :issue_id)
    type = native_value(issue, :content_type)
    current_state = native_value(issue, :issue_state) |> to_string() |> String.downcase()
    current_reason = native_value(issue, :issue_state_reason) |> to_string() |> String.downcase()

    cond do
      type != "Issue" ->
        {:error, :managed_native_issue_required, %{}}

      current_state == "closed" and current_reason == "completed" ->
        :ok

      current_state == "closed" ->
        {:error, :managed_issue_closed_with_wrong_reason, %{reason: current_reason}}

      not is_binary(id) ->
        {:error, :managed_native_issue_id_missing, %{}}

      true ->
        case graphql(@close_issue_mutation, %{"issueId" => id}) do
          {:ok, body} -> close_response_ok(body, type, id)
          {:error, reason} -> {:error, :managed_issue_close_failed, %{reason: inspect(reason)}}
          _ -> {:error, :managed_issue_close_failed, %{}}
        end
    end
  end

  defp close_response_ok(%{"data" => %{"closeIssue" => %{"issue" => %{"id" => id, "state" => state, "stateReason" => reason}}}}, "Issue", expected)
       when id == expected and state == "CLOSED" and reason == "COMPLETED", do: :ok

  defp close_response_ok(_body, _type, _expected), do: {:error, :managed_issue_close_unconfirmed, %{}}

  defp set_project_status(issue, context, option_id) do
    project_id = native_value(issue, :project_id)
    item_id = native_value(issue, :project_item_id)
    field_id = get_in(context, [:binding, :status_field_id])

    with true <- Enum.all?([project_id, item_id, field_id, option_id], &is_binary/1),
         {:ok, body} <- graphql(@status_mutation, %{"projectId" => project_id, "itemId" => item_id, "fieldId" => field_id, "optionId" => option_id}),
         :ok <- status_response_ok(body, item_id) do
      :ok
    else
      false -> {:error, :managed_project_status_identity_missing, %{}}
      {:error, reason} -> {:error, :managed_project_status_failed, %{reason: inspect(reason)}}
      _ -> {:error, :managed_project_status_failed, %{}}
    end
  end

  defp status_response_ok(%{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => id}}}}, expected)
       when id == expected, do: :ok

  defp status_response_ok(_body, _expected), do: {:error, :managed_project_status_unconfirmed, %{}}

  defp status_option(context, target) do
    name = target |> Atom.to_string() |> String.upcase()
    options = get_in(context, [:binding, :status_options]) || %{}

    case options do
      options when is_map(options) ->
        case Enum.find(options, fn {key, _id} -> String.upcase(to_string(key)) == name end) do
          {_, id} when is_binary(id) -> {:ok, id}
          _ -> {:error, :managed_status_option_missing, %{status: target}}
        end

      _ ->
        {:error, :managed_status_option_missing, %{status: target}}
    end
  end

  defp graphql(query, variables) do
    opts =
      case Application.get_env(:symphony_elixir, :managed_github_request_fun) do
        request_fun when is_function(request_fun) -> [request_fun: request_fun]
        _ -> []
      end

    Client.graphql(query, variables, opts)
  end

  defp native_value(issue, key), do: get_in(issue.native_ref || %{}, [Atom.to_string(key)])
  defp text(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp text(_map, _key), do: nil
end
