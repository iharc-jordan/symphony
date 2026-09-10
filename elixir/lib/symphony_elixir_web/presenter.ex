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
    case value(snapshot, :managed) do
      managed when is_map(managed) ->
        managed_state_payload(managed)

      _ ->
        case Control.state(orchestrator, snapshot_timeout_ms) do
          {:ok, state} when is_map(state) -> managed_state_payload(state)
          _ -> nil
        end
    end
  end

  defp managed_state_payload(state) do
    binding = value(state, :binding) || %{}
    projects = sanitize_projects(value(state, :projects) || binding)
    principals = sanitize_principals(value(state, :principals) || %{})
    assignments = sanitize_assignments(value(state, :assignments) || %{}, principals, binding)

    %{
      status: "available",
      revision: integer_or_zero(value(state, :revision) || value(state, :control_revision)),
      cursor: integer_or_zero(value(state, :cursor) || value(state, :event_cursor)),
      paused: value(state, :paused) == true,
      disabled: value(state, :disabled) == true,
      dispatch_paused: value(state, :paused) == true or value(state, :disabled) == true,
      projects: projects,
      principals: principals,
      assignments: assignments,
      counts: managed_counts(assignments),
      handoffs: handoff_history(value(state, :events) || []),
      projection: projection_summary(assignments)
    }
  end

  defp sanitize_projects(projects) when is_map(projects) do
    Enum.reduce(projects, %{}, fn {key, project}, acc ->
      project = if is_map(project), do: project, else: %{}
      project_id = text_value(value(project, :project_id) || key)

      if project_id do
        Map.put(
          acc,
          project_id,
          compact(%{
            project_id: project_id,
            project_number: value(project, :project_number),
            status_field_id: text_value(value(project, :status_field_id)),
            status_field_name: text_value(value(project, :status_field_name)),
            owner: text_value(value(project, :owner)),
            owner_type: text_value(value(project, :owner_type)),
            repositories: safe_repositories(value(project, :repositories)),
            status_options: safe_status_options(value(project, :status_options)),
            revision: integer_or_zero(value(project, :revision))
          })
        )
      else
        acc
      end
    end)
  end

  defp sanitize_projects(projects) when is_list(projects) do
    sanitize_projects(Map.new(projects, fn project -> {value(project, :project_id), project} end))
  end

  defp sanitize_projects(_projects), do: %{}

  defp sanitize_principals(principals) when is_map(principals) do
    Enum.reduce(principals, %{}, fn {key, principal}, acc ->
      principal = if is_map(principal), do: principal, else: %{}
      source_id = text_value(value(principal, :principal_id) || key)
      task_id = text_value(value(principal, :task_id) || value(principal, :task_uuid))
      principal_id = task_id || source_id

      if principal_id do
        display_name = text_value(value(principal, :display_name) || value(principal, :name) || value(principal, :title))

        Map.put(
          acc,
          principal_id,
          %{
            principal_id: source_id || principal_id,
            display_name: display_name || principal_id,
            role: text_value(value(principal, :role)),
            task_id: task_id || principal_id,
            title: text_value(value(principal, :title))
          }
        )
      else
        acc
      end
    end)
  end

  defp sanitize_principals(_principals), do: %{}

  defp principal_display_name(principals, principal_id) do
    get_in(principals, [principal_id, :display_name]) ||
      Enum.find_value(principals, fn {_task_id, principal} ->
        if Map.get(principal, :principal_id) == principal_id, do: Map.get(principal, :display_name)
      end)
  end

  defp sanitize_assignments(assignments, principals, binding) when is_map(assignments) do
    project_id = text_value(value(binding, :project_id))

    Enum.reduce(assignments, %{}, fn {key, assignment}, acc ->
      assignment = if is_map(assignment), do: assignment, else: %{}
      assignment_id = text_value(value(assignment, :assignment_id) || key)

      if assignment_id do
        Map.put(acc, assignment_id, assignment_payload(assignment, assignment_id, project_id, principals))
      else
        acc
      end
    end)
  end

  defp sanitize_assignments(assignments, principals, binding) when is_list(assignments) do
    sanitize_assignments(
      Map.new(assignments, fn assignment -> {value(assignment, :assignment_id), assignment} end),
      principals,
      binding
    )
  end

  defp sanitize_assignments(_assignments, _principals, _binding), do: %{}

  defp assignment_payload(assignment, assignment_id, default_project_id, principals) do
    ownership_raw = value(assignment, :ownership) || %{}
    owner_raw = value(assignment, :owner) || %{}
    pm_id = text_value(value(ownership_raw, :pm_id) || value(owner_raw, :pm_id) || value(owner_raw, :principal_id))
    projection = projection_payload(value(assignment, :projection))
    phase = phase_name(value(assignment, :phase) || value(assignment, :board_state) || value(assignment, :status))
    status = text_value(value(assignment, :status) || value(assignment, :board_state) || value(assignment, :phase)) || "unknown"
    task_id = text_value(value(assignment, :task_uuid) || value(assignment, :task_id) || value(assignment, :thread_id) || value(assignment, :session_id))
    owner_name = pm_id && principal_display_name(principals, pm_id)

    ownership_status =
      text_value(value(ownership_raw, :status)) ||
        if(
          value(ownership_raw, :needs_claim) == true,
          do: "needs_claim",
          else: if(pm_id, do: "owned", else: "unassigned")
        )

    title = text_value(value(assignment, :title) || value(assignment, :task_title) || value(assignment, :issue_title))

    compact(%{
      assignment_id: assignment_id,
      project_id: text_value(value(assignment, :project_id)) || default_project_id,
      repository: text_value(value(assignment, :repository)),
      issue_number: value(assignment, :issue_number),
      title: title,
      task: %{id: task_id, title: title},
      phase: phase,
      status: status,
      board_state: text_value(value(assignment, :board_state)),
      ownership: %{
        pm_id: pm_id,
        display_name: owner_name || text_value(value(owner_raw, :display_name) || value(owner_raw, :name)),
        status: ownership_status,
        ownership_revision: integer_or_nil(value(ownership_raw, :ownership_revision) || value(ownership_raw, :revision))
      },
      dispatch_paused: value(assignment, :dispatch_paused) == true,
      operator_reconciliation_required: value(assignment, :operator_reconciliation_required) == true,
      worker: safe_worker(assignment),
      projection: projection,
      reports: safe_reports(value(assignment, :reports) || value(assignment, :report)),
      usage: safe_usage(value(assignment, :usage)),
      attempt: safe_attempt(value(assignment, :attempt)),
      thread: safe_thread(assignment),
      workspace: safe_workspace(assignment)
    })
  end

  defp projection_payload(nil), do: %{status: "unknown", revision: nil, updated_at: nil, synced_at: nil, retry_at: nil, error: nil, stale: true}

  defp projection_payload(projection) when is_map(projection) do
    status = projection_status(value(projection, :status))
    updated_at = iso8601(value(projection, :updated_at))
    synced_at = iso8601(value(projection, :synced_at))
    retry_at = iso8601(value(projection, :retry_at))

    %{
      status: status,
      revision: integer_or_nil(value(projection, :revision)),
      updated_at: updated_at,
      synced_at: synced_at,
      retry_at: retry_at,
      error: safe_text(value(projection, :error)),
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
    status != "synced" or is_nil(updated_at) or
      case DateTime.from_iso8601(updated_at) do
        {:ok, timestamp, _offset} ->
          DateTime.diff(DateTime.utc_now(), timestamp, :second) > @projection_stale_after_seconds

        _ ->
          true
      end
  end

  defp safe_reports(nil), do: []

  defp safe_reports(reports) when is_list(reports) do
    Enum.map(reports, fn report ->
      if is_map(report) do
        compact(%{
          kind: text_value(value(report, :kind) || value(report, :type)),
          status: text_value(value(report, :status)),
          updated_at: iso8601(value(report, :updated_at)),
          count: value(report, :count)
        })
      else
        %{status: "available"}
      end
    end)
  end

  defp safe_reports(report) when is_map(report), do: safe_reports([report])
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
    worker = value(assignment, :worker) || %{}
    active = if is_nil(value(assignment, :worker_active)), do: value(worker, :active), else: value(assignment, :worker_active)

    %{
      id: text_value(value(assignment, :worker_id) || value(assignment, :agent_id) || value(worker, :id) || value(worker, :worker_id)),
      active: active,
      activity: text_value(value(assignment, :worker_activity) || value(assignment, :activity) || value(worker, :activity))
    }
  end

  defp safe_thread(assignment) do
    thread = value(assignment, :thread) || %{}

    %{
      id: text_value(value(assignment, :thread_id) || value(assignment, :session_id) || value(assignment, :task_uuid) || value(thread, :id) || value(thread, :thread_id)),
      title: text_value(value(assignment, :title) || value(assignment, :task_title) || value(thread, :title))
    }
  end

  defp safe_workspace(assignment) do
    workspace = value(assignment, :workspace)

    compact(%{
      present: not is_nil(workspace) or not is_nil(value(assignment, :workspace_path)),
      status: if(is_map(workspace), do: text_value(value(workspace, :status)), else: nil),
      branch: if(is_map(workspace), do: text_value(value(workspace, :branch)), else: nil)
    })
  end

  defp managed_counts(assignments) do
    values = Map.values(assignments)

    %{
      running: Enum.count(values, &(Map.get(&1, :phase) == "active")),
      queued: Enum.count(values, &(Map.get(&1, :phase) in ["bound", "ready", "queued"])),
      review: Enum.count(values, &(Map.get(&1, :phase) == "review")),
      waiting: Enum.count(values, &(Map.get(&1, :phase) in ["waiting", "rework"])),
      blocked:
        Enum.count(values, fn assignment ->
          Map.get(assignment, :dispatch_paused) == true or
            get_in(assignment, [:projection, :status]) in ["failed", "unknown"] or
            get_in(assignment, [:ownership, :status]) == "needs_claim" or
            Map.get(assignment, :operator_reconciliation_required) == true or
            String.downcase(Map.get(assignment, :status, "")) in ["blocked", "failed", "error"]
        end)
    }
  end

  defp projection_summary(assignments) do
    values = Map.values(assignments)

    errors =
      values
      |> Enum.filter(&(get_in(&1, [:projection, :status]) == "failed"))
      |> Enum.map(fn assignment ->
        %{assignment_id: assignment.assignment_id, error: get_in(assignment, [:projection, :error]) || "Projection failed"}
      end)

    stale = Enum.any?(values, &get_in(&1, [:projection, :stale]))

    status =
      cond do
        errors != [] -> "failed"
        stale -> "stale"
        Enum.any?(values, &(get_in(&1, [:projection, :status]) == "pending")) -> "pending"
        true -> "synced"
      end

    %{status: status, stale: stale, errors: errors}
  end

  defp handoff_history(events) when is_list(events) do
    events
    |> Enum.filter(fn event -> event_operation(event) in ["handoff", "operator_takeover"] end)
    |> Enum.take(20)
    |> Enum.map(fn event ->
      %{
        cursor: value(event, :cursor),
        at: iso8601(value(event, :at)),
        operation: event_operation(event),
        source_id: text_value(value(event, :source_id) || value(event, :source_pm_id) || value(event, :from)),
        destination_id: text_value(value(event, :destination_id) || value(event, :destination_pm_id) || value(event, :to)),
        assignment_id: text_value(value(event, :assignment_id)),
        assignment_ids: safe_id_list(value(event, :assignment_ids)),
        reason: safe_text(value(event, :reason))
      }
    end)
  end

  defp handoff_history(_events), do: []

  defp event_operation(event) when is_map(event), do: text_value(value(event, :operation))
  defp event_operation(_event), do: nil

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

  defp safe_status_options(options) when is_list(options) do
    safe_status_options(Map.new(options, fn item -> {value(item, :name), value(item, :id)} end))
  end

  defp safe_status_options(_options), do: %{}

  defp integer_or_zero(value) when is_integer(value), do: value
  defp integer_or_zero(_value), do: 0
  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp phase_name(value) do
    value
    |> text_value()
    |> case do
      nil -> "unknown"
      phase -> String.downcase(phase)
    end
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil

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
