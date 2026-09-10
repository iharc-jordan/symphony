defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Workspace}
  alias SymphonyElixir.Managed.Control
  @projection_stale_after_seconds 300

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }
        |> maybe_put_managed(managed_payload(orchestrator, snapshot_timeout_ms, snapshot))

      :timeout ->
        %{
          generated_at: generated_at,
          error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
        }

      :unavailable ->
        %{
          generated_at: generated_at,
          error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}
        }
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp maybe_put_managed(payload, nil), do: payload
  defp maybe_put_managed(payload, managed), do: Map.put(payload, :managed, managed)

  defp managed_payload(orchestrator, snapshot_timeout_ms, snapshot) do
    case Map.get(snapshot, :managed) do
      managed when is_map(managed) -> managed_state_payload(managed)
      _ -> fetch_managed_payload(orchestrator, snapshot_timeout_ms)
    end
  end

  defp fetch_managed_payload(orchestrator, snapshot_timeout_ms) do
    case Control.state(orchestrator, snapshot_timeout_ms) do
      {:ok, state} when is_map(state) -> managed_state_payload(state)
      _ -> nil
    end
  end

  defp managed_state_payload(state) do
    principals = sanitize_principals(Map.get(state, :principals, %{}))
    assignments = sanitize_assignments(Map.get(state, :assignments, %{}), principals)
    paused = Map.get(state, :paused, false)
    disabled = Map.get(state, :disabled, false)

    %{
      status: "available",
      revision: Map.get(state, :revision, 0),
      cursor: Map.get(state, :cursor, 0),
      paused: paused,
      disabled: disabled,
      dispatch_paused: paused or disabled,
      projects: sanitize_projects(Map.get(state, :projects, %{})),
      principals: principals,
      assignments: assignments,
      counts: managed_counts(assignments),
      handoffs: handoff_history(Map.get(state, :events, [])),
      projection: projection_summary(assignments)
    }
  end

  defp sanitize_projects(projects) when is_map(projects) do
    Enum.reduce(projects, %{}, fn {key, project}, acc -> put_project(acc, key, project) end)
  end

  defp sanitize_projects(_projects), do: %{}

  defp put_project(acc, key, project) when is_map(project) do
    project_id = text_value(Map.get(project, :project_id) || key)

    if project_id do
      Map.put(acc, project_id, project_payload(project, project_id))
    else
      acc
    end
  end

  defp put_project(acc, _key, _project), do: acc

  defp project_payload(project, project_id) do
    compact(%{
      project_id: project_id,
      project_number: Map.get(project, :project_number),
      status_field_id: text_value(Map.get(project, :status_field_id)),
      status_field_name: text_value(Map.get(project, :status_field_name)),
      owner: text_value(Map.get(project, :owner)),
      owner_type: text_value(Map.get(project, :owner_type)),
      repositories: safe_repositories(Map.get(project, :repositories)),
      status_options: safe_status_options(Map.get(project, :status_options)),
      revision: Map.get(project, :revision, 0)
    })
  end

  defp sanitize_principals(principals) when is_map(principals) do
    Enum.reduce(principals, %{}, fn {key, principal}, acc -> put_principal(acc, key, principal) end)
  end

  defp sanitize_principals(_principals), do: %{}

  defp put_principal(acc, key, principal) when is_map(principal) do
    source_id = text_value(Map.get(principal, :principal_id) || key)
    task_id = text_value(Map.get(principal, :task_uuid)) || source_id

    if task_id do
      Map.put(acc, task_id, principal_payload(principal, source_id, task_id))
    else
      acc
    end
  end

  defp put_principal(acc, _key, _principal), do: acc

  defp principal_payload(principal, source_id, task_id) do
    %{
      principal_id: source_id || task_id,
      display_name: text_value(Map.get(principal, :display_name)) || task_id,
      role: text_value(Map.get(principal, :role)),
      task_id: task_id,
      title: text_value(Map.get(principal, :title))
    }
  end

  defp principal_display_name(principals, principal_id) do
    case Map.get(principals, principal_id) do
      %{display_name: display_name} -> display_name
      _ -> find_principal_display_name(principals, principal_id)
    end
  end

  defp find_principal_display_name(principals, principal_id) do
    Enum.find_value(principals, fn {_task_id, principal} ->
      if Map.get(principal, :principal_id) == principal_id, do: Map.get(principal, :display_name)
    end)
  end

  defp sanitize_assignments(assignments, principals) when is_map(assignments) do
    Enum.reduce(assignments, %{}, fn {key, assignment}, acc ->
      put_assignment(acc, key, assignment, principals)
    end)
  end

  defp sanitize_assignments(_assignments, _principals), do: %{}

  defp put_assignment(acc, key, assignment, principals) when is_map(assignment) do
    assignment_id = text_value(Map.get(assignment, :assignment_id) || key)

    if assignment_id do
      Map.put(acc, assignment_id, assignment_payload(assignment, assignment_id, principals))
    else
      acc
    end
  end

  defp put_assignment(acc, _key, _assignment, _principals), do: acc

  defp assignment_payload(assignment, assignment_id, principals) do
    projection = projection_payload(Map.get(assignment, :projection))
    title = text_value(Map.get(assignment, :title))

    compact(%{
      assignment_id: assignment_id,
      project_id: text_value(Map.get(assignment, :project_id)),
      repository: text_value(Map.get(assignment, :repository)),
      issue_number: Map.get(assignment, :issue_number),
      issue_url: managed_issue_url(assignment),
      title: title,
      task: %{id: text_value(Map.get(assignment, :task_uuid)), title: title},
      phase: phase_name(Map.get(assignment, :phase)),
      status: assignment_status(assignment),
      board_state: text_value(Map.get(assignment, :board_state)),
      ownership: ownership_payload(Map.get(assignment, :ownership), principals),
      dispatch_paused: Map.get(assignment, :dispatch_paused) == true,
      operator_reconciliation_required: Map.get(assignment, :operator_reconciliation_required) == true,
      worker: safe_worker(assignment),
      projection: projection,
      reports: safe_reports(Map.get(assignment, :reports)),
      usage: safe_usage(Map.get(assignment, :usage)),
      attempt: safe_attempt(Map.get(assignment, :attempt)),
      thread: safe_thread(assignment),
      workspace: safe_workspace(assignment)
    })
  end

  defp managed_issue_url(%{repository: repository, issue_number: number})
       when is_binary(repository) and is_integer(number) and number > 0 do
    "https://github.com/#{repository}/issues/#{number}"
  end

  defp managed_issue_url(_assignment), do: nil

  defp assignment_status(assignment) do
    text_value(Map.get(assignment, :status) || Map.get(assignment, :board_state) || Map.get(assignment, :phase)) || "unknown"
  end

  defp ownership_payload(ownership, principals) when is_map(ownership) do
    pm_id = text_value(Map.get(ownership, :pm_id))

    %{
      pm_id: pm_id,
      display_name: principal_display_name(principals, pm_id),
      status: ownership_status(ownership, pm_id),
      ownership_revision: integer_or_nil(Map.get(ownership, :ownership_revision))
    }
  end

  defp ownership_payload(_ownership, _principals) do
    %{pm_id: nil, display_name: nil, status: "unassigned", ownership_revision: nil}
  end

  defp ownership_status(ownership, pm_id) do
    case text_value(Map.get(ownership, :status)) do
      nil -> if(pm_id, do: "owned", else: "unassigned")
      status -> status
    end
  end

  defp projection_payload(nil) do
    %{status: "unknown", revision: nil, updated_at: nil, synced_at: nil, retry_at: nil, error: nil, stale: true}
  end

  defp projection_payload(projection) when is_map(projection) do
    status = projection_status(Map.get(projection, :status))
    updated_at = iso8601(Map.get(projection, :updated_at))

    %{
      status: status,
      revision: integer_or_nil(Map.get(projection, :revision)),
      updated_at: updated_at,
      synced_at: iso8601(Map.get(projection, :synced_at)),
      retry_at: iso8601(Map.get(projection, :retry_at)),
      error: safe_text(Map.get(projection, :error)),
      stale: projection_stale?(status, updated_at)
    }
  end

  defp projection_payload(_projection), do: projection_payload(nil)

  defp projection_status(status) do
    case status |> text_value() |> to_string() |> String.downcase() do
      "synced" -> "synced"
      "pending" -> "pending"
      "failed" -> "failed"
      _ -> "unknown"
    end
  end

  defp projection_stale?(status, updated_at) do
    status != "synced" or is_nil(updated_at) or stale_timestamp?(updated_at)
  end

  defp stale_timestamp?(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, timestamp, _offset} -> DateTime.diff(DateTime.utc_now(), timestamp, :second) > @projection_stale_after_seconds
      _ -> true
    end
  end

  defp safe_reports(nil), do: []

  defp safe_reports(reports) when is_list(reports) do
    Enum.map(reports, fn report ->
      if is_map(report) do
        compact(%{
          kind: text_value(Map.get(report, :kind)),
          status: text_value(Map.get(report, :status)),
          updated_at: iso8601(Map.get(report, :updated_at)),
          count: Map.get(report, :count)
        })
      else
        %{status: "available"}
      end
    end)
  end

  defp safe_reports(_reports), do: []

  defp safe_usage(nil), do: %{}

  defp safe_usage(usage) when is_map(usage) do
    usage
    |> Map.take([:baseline_tokens, :cumulative_tokens, :inflight_tokens, :overshoot_tokens, :cap_reached, :limit_tokens, :input_tokens, :output_tokens, :total_tokens])
    |> Enum.reduce(%{}, fn {key, val}, acc ->
      if is_integer(val) or is_float(val) or is_boolean(val), do: Map.put(acc, key, val), else: acc
    end)
  end

  defp safe_usage(_usage), do: %{}

  defp safe_attempt(nil), do: %{}

  defp safe_attempt(attempt) when is_map(attempt) do
    attempt
    |> Map.take([:id, :number, :attempt, :status, :started_at, :completed_at, :retry_count, :turn_count])
    |> Enum.reduce(%{}, fn {key, val}, acc ->
      value = if key in [:started_at, :completed_at], do: iso8601(val), else: val
      if is_binary(value) or is_integer(value) or is_boolean(value), do: Map.put(acc, key, value), else: acc
    end)
  end

  defp safe_attempt(attempt) when is_integer(attempt), do: %{number: attempt}
  defp safe_attempt(_attempt), do: %{}

  defp safe_worker(assignment) do
    %{
      id: text_value(Map.get(assignment, :worker_id)),
      active: Map.get(assignment, :worker_active),
      activity: text_value(Map.get(assignment, :worker_activity))
    }
  end

  defp safe_thread(assignment) do
    %{
      id: text_value(Map.get(assignment, :thread_id) || Map.get(assignment, :session_id)),
      title: text_value(Map.get(assignment, :title))
    }
  end

  defp safe_workspace(assignment) do
    workspace = Map.get(assignment, :workspace)

    compact(%{
      present: not is_nil(workspace) or not is_nil(Map.get(assignment, :workspace_path)),
      status: workspace_value(workspace, :status),
      branch: workspace_value(workspace, :branch)
    })
  end

  defp workspace_value(workspace, key) when is_map(workspace), do: text_value(Map.get(workspace, key))
  defp workspace_value(_workspace, _key), do: nil

  defp managed_counts(assignments) do
    values = Map.values(assignments)

    %{
      running: Enum.count(values, &(Map.get(&1, :phase) == "active")),
      queued: Enum.count(values, &(Map.get(&1, :phase) in ["bound", "ready", "queued"])),
      review: Enum.count(values, &(Map.get(&1, :phase) == "review")),
      waiting: Enum.count(values, &(Map.get(&1, :phase) in ["waiting", "rework"])),
      blocked: Enum.count(values, &blocked_assignment?/1)
    }
  end

  defp blocked_assignment?(assignment) do
    Map.get(assignment, :dispatch_paused) == true or
      get_in(assignment, [:projection, :status]) in ["failed", "unknown"] or
      get_in(assignment, [:ownership, :status]) == "needs_claim" or
      Map.get(assignment, :operator_reconciliation_required) == true or
      String.downcase(Map.get(assignment, :status, "")) in ["blocked", "failed", "error"]
  end

  defp projection_summary(assignments) do
    values = Map.values(assignments)
    errors = projection_errors(values)
    stale = Enum.any?(values, &get_in(&1, [:projection, :stale]))
    status = projection_summary_status(errors, stale, values)

    %{status: status, stale: stale, errors: errors}
  end

  defp projection_errors(assignments) do
    assignments
    |> Enum.filter(&(get_in(&1, [:projection, :status]) == "failed"))
    |> Enum.map(fn assignment ->
      %{assignment_id: assignment.assignment_id, error: get_in(assignment, [:projection, :error]) || "Projection failed"}
    end)
  end

  defp projection_summary_status(errors, _stale, _assignments) when errors != [], do: "failed"
  defp projection_summary_status(_errors, true, _assignments), do: "stale"

  defp projection_summary_status(_errors, false, assignments) do
    if Enum.any?(assignments, &(get_in(&1, [:projection, :status]) == "pending")), do: "pending", else: "synced"
  end

  defp handoff_history(events) when is_list(events) do
    events
    |> Enum.filter(&handoff_event?/1)
    |> Enum.take(20)
    |> Enum.map(&handoff_payload/1)
  end

  defp handoff_history(_events), do: []

  defp handoff_event?(%{operation: operation}), do: operation in [:handoff, :operator_takeover]
  defp handoff_event?(_event), do: false

  defp handoff_payload(event) do
    %{
      cursor: Map.get(event, :cursor),
      at: iso8601(Map.get(event, :at)),
      operation: text_value(Map.get(event, :operation)),
      status: text_value(Map.get(event, :status)),
      source_id: text_value(Map.get(event, :source_pm_id)),
      destination_id: text_value(Map.get(event, :destination_pm_id)),
      assignment_id: text_value(Map.get(event, :assignment_id)),
      assignment_ids: safe_id_list(Map.get(event, :assignment_ids)),
      reason: safe_text(Map.get(event, :reason))
    }
  end

  defp safe_id_list(ids) when is_list(ids), do: ids |> Enum.map(&text_value/1) |> Enum.reject(&is_nil/1)
  defp safe_id_list(id), do: if(text_value(id), do: [text_value(id)], else: [])

  defp safe_repositories(repositories) when is_list(repositories) do
    repositories |> Enum.map(&text_value/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp safe_repositories(_repositories), do: []

  defp safe_status_options(options) when is_map(options) do
    Enum.reduce(options, %{}, fn {key, option_id}, acc ->
      case {text_value(key), text_value(option_id)} do
        {name, id} when not is_nil(name) and not is_nil(id) -> Map.put(acc, name, id)
        _ -> acc
      end
    end)
  end

  defp safe_status_options(_options), do: %{}

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp phase_name(phase) do
    case text_value(phase) do
      nil -> "unknown"
      phase -> String.downcase(phase)
    end
  end

  defp text_value(nil), do: nil

  defp text_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: String.slice(value, 0, 240)
  end

  defp text_value(value) when is_atom(value), do: value |> Atom.to_string() |> text_value()
  defp text_value(value) when is_integer(value), do: Integer.to_string(value)
  defp text_value(_value), do: nil

  defp safe_text(nil), do: nil

  defp safe_text(value) when is_binary(value) do
    value
    |> String.replace(~r{(?:[A-Za-z]:[\/]|/(?:home|Users|tmp|workspaces)/)\S+}, "[path]")
    |> text_value()
  end

  defp safe_text(value), do: value |> inspect(limit: 20, printable_limit: 240) |> text_value()

  defp compact(map), do: Enum.reject(map, fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, Workspace.workspace_key(issue_identifier))
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
