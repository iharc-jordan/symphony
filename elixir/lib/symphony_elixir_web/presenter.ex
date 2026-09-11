defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, Workspace}
  alias SymphonyElixir.Managed.Control
  alias SymphonyElixirWeb.ManagedStateView
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
      managed when is_map(managed) -> managed_state_payload(managed, snapshot)
      _ -> fetch_managed_payload(orchestrator, snapshot_timeout_ms, snapshot)
    end
  end

  defp fetch_managed_payload(orchestrator, snapshot_timeout_ms, snapshot) do
    case Control.state(orchestrator, snapshot_timeout_ms) do
      {:ok, state} when is_map(state) -> managed_state_payload(state, snapshot)
      _ -> nil
    end
  end

  defp managed_state_payload(state, snapshot) do
    principals = sanitize_principals(Map.get(state, :principals, %{}))
    source_assignments = Map.get(state, :assignments, %{})

    max_agents =
      case Config.settings() do
        {:ok, settings} -> settings.agent.max_concurrent_agents
        _ -> nil
      end

    facts = %{max_concurrent_agents: max_agents, running_count: length(snapshot.running)}

    assignments =
      source_assignments
      |> sanitize_assignments(principals)
      |> Map.new(fn {id, assignment} ->
        {id, Map.put(assignment, :wait_reason, ManagedStateView.wait_reason(Map.get(source_assignments, id, %{}), state, facts))}
      end)

    paused = Map.get(state, :paused, false)
    disabled = Map.get(state, :disabled, false)

    %{
      status: "available",
      revision: Map.get(state, :revision, 0),
      cursor: Map.get(state, :cursor, 0),
      paused: paused,
      disabled: disabled,
      dispatch_paused: paused or disabled,
      usage: safe_usage(Map.get(state, :usage)),
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
    projection = assignment_projection(assignment)
    title = text_value(field_value(assignment, :title))

    compact(%{
      assignment_id: assignment_id,
      project_id: text_value(field_value(assignment, :project_id)),
      repository: text_value(field_value(assignment, :repository)),
      issue_number: field_value(assignment, :issue_number),
      issue_url: managed_issue_url(assignment),
      title: title,
      task: %{id: text_value(field_value(assignment, :task_uuid)), title: title},
      phase: phase_name(field_value(assignment, :phase)),
      status: assignment_status(assignment),
      board_state: text_value(field_value(assignment, :board_state)),
      ownership: ownership_payload(field_value(assignment, :ownership), principals),
      dispatch_paused: field_value(assignment, :dispatch_paused) == true,
      stop_pending: field_value(assignment, :stop_pending) == true,
      route: assignment_route(assignment),
      last_report: safe_last_report(field_value(assignment, :last_report)),
      blocked_reason: safe_text(field_value(assignment, :blocked_reason)),
      started_at: iso8601(field_value(assignment, :started_at)),
      worker: safe_worker(assignment),
      projection: projection,
      reports: safe_reports(field_value(assignment, :reports)),
      usage: safe_usage(field_value(assignment, :usage)),
      attempt: safe_attempt(field_value(assignment, :attempt)),
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

  defp assignment_projection(assignment) do
    case Map.fetch(assignment, :projection) do
      {:ok, projection} when is_map(projection) -> projection_payload(projection)
      {:ok, nil} -> projection_payload(projection_from_pending_effect(field_value(assignment, :pending_effect)))
      :error -> projection_payload(projection_from_pending_effect(field_value(assignment, :pending_effect)))
      _ -> projection_payload(nil)
    end
  end

  defp projection_from_pending_effect(effect) when is_map(effect) do
    kind = field_value(effect, :kind)
    status = projection_status(field_value(effect, :status))
    updated_at = projection_timestamp(field_value(effect, :at) || field_value(effect, :updated_at))

    if kind in [:provider_transition, "provider_transition"] and
         status in ["synced", "pending", "failed"] and is_binary(updated_at) do
      %{
        status: status,
        revision: integer_or_nil(field_value(effect, :revision)),
        updated_at: updated_at,
        synced_at: if(status == "synced", do: updated_at, else: nil),
        retry_at: iso8601(field_value(effect, :retry_at)),
        error: safe_text(field_value(effect, :error) || field_value(effect, :reason))
      }
    else
      nil
    end
  end

  defp projection_from_pending_effect(_effect), do: nil

  defp projection_payload(nil) do
    %{status: "unknown", revision: nil, updated_at: nil, synced_at: nil, retry_at: nil, error: nil, stale: false}
  end

  defp projection_payload(projection) when is_map(projection) do
    status = projection_status(field_value(projection, :status))
    updated_at = projection_timestamp(field_value(projection, :updated_at))

    %{
      status: status,
      revision: integer_or_nil(field_value(projection, :revision)),
      updated_at: updated_at,
      synced_at: projection_timestamp(field_value(projection, :synced_at)),
      retry_at: projection_timestamp(field_value(projection, :retry_at)),
      error: safe_text(field_value(projection, :error)),
      stale: projection_stale?(status, updated_at)
    }
  end

  defp projection_status(status) do
    case status |> text_value() |> to_string() |> String.downcase() do
      "synced" -> "synced"
      "reconciled" -> "synced"
      "pending" -> "pending"
      "retry_pending" -> "pending"
      "failed" -> "failed"
      _ -> "unknown"
    end
  end

  defp projection_stale?("unknown", _updated_at), do: false

  defp projection_stale?(status, updated_at) do
    status != "synced" or is_nil(updated_at) or stale_timestamp?(updated_at)
  end

  defp projection_timestamp(%DateTime{} = timestamp), do: iso8601(timestamp)

  defp projection_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> iso8601(parsed)
      _ -> nil
    end
  end

  defp projection_timestamp(_timestamp), do: nil

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
    |> Map.take([
      :baseline_tokens,
      :cumulative_tokens,
      :inflight_tokens,
      :overshoot_tokens,
      :cap_reached,
      :limit_tokens,
      :input_tokens,
      :cached_input_tokens,
      :output_tokens,
      :total_tokens,
      :seconds_running,
      :telemetry_complete,
      :runtime_complete,
      :accounting_status
    ])
    |> Enum.reduce(%{}, fn {key, val}, acc ->
      cond do
        key == :accounting_status and val in [:known, :unavailable, "known", "unavailable"] -> Map.put(acc, key, to_string(val))
        is_integer(val) or is_float(val) or is_boolean(val) -> Map.put(acc, key, val)
        true -> acc
      end
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
      id: text_value(field_value(assignment, :worker_id)),
      host: text_value(field_value(assignment, :worker_host)),
      active: field_value(assignment, :worker_active) == true,
      activity: safe_text(field_value(assignment, :worker_activity))
    }
  end

  defp assignment_route(assignment) do
    route = field_value(assignment, :route) || %{}
    turn_model = text_value(field_value(assignment, :turn_model))
    active = nonterminal_assignment?(assignment) and field_value(assignment, :worker_active) == true

    if active and not is_nil(turn_model) do
      %{model: turn_model, effort: text_value(field_value(assignment, :turn_effort)), source: "running"}
    else
      %{model: text_value(field_value(route, :model)), effort: text_value(field_value(route, :effort)), source: "configured"}
    end
  end

  defp safe_last_report(nil), do: %{kind: nil, summary: nil, evidence: []}

  defp safe_last_report(report) when is_map(report) do
    %{
      kind: safe_report_text(field_value(report, :kind)),
      summary: safe_report_text(field_value(report, :summary)),
      evidence: safe_report_evidence(field_value(report, :evidence))
    }
  end

  defp safe_last_report(_report), do: %{kind: nil, summary: nil, evidence: []}

  defp safe_report_evidence(evidence) when is_list(evidence) do
    evidence
    |> Enum.map(&safe_report_evidence_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp safe_report_evidence(_evidence), do: []

  defp safe_report_text(value) when is_binary(value), do: safe_text(value)
  defp safe_report_text(value) when is_atom(value), do: safe_text(value)
  defp safe_report_text(value) when is_integer(value), do: safe_text(value)
  defp safe_report_text(value) when is_float(value), do: safe_text(value)
  defp safe_report_text(value) when is_boolean(value), do: safe_text(value)
  defp safe_report_text(_value), do: nil

  defp safe_report_evidence_item(value) when is_binary(value), do: safe_text(value)
  defp safe_report_evidence_item(value) when is_atom(value), do: safe_text(value)
  defp safe_report_evidence_item(value) when is_integer(value), do: safe_text(value)
  defp safe_report_evidence_item(value) when is_float(value), do: safe_text(value)
  defp safe_report_evidence_item(value) when is_boolean(value), do: safe_text(value)
  defp safe_report_evidence_item(_value), do: nil

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
    values = assignments |> Map.values() |> Enum.filter(&nonterminal_assignment?/1)

    %{
      running: Enum.count(values, &worker_active?/1),
      queued: Enum.count(values, &(phase_name(field_value(&1, :phase)) in ["bound", "ready"])),
      review: Enum.count(values, &(phase_name(field_value(&1, :phase)) in ["review", "review_pending"])),
      waiting: Enum.count(values, &(phase_name(field_value(&1, :phase)) == "waiting")),
      blocked: Enum.count(values, &blocked_assignment?/1)
    }
  end

  defp nonterminal_assignment?(assignment) do
    phase_name(field_value(assignment, :phase)) not in ["accepted", "cancelled"]
  end

  defp worker_active?(assignment), do: field_value(assignment, :worker_active) == true or get_in(assignment, [:worker, :active]) == true

  defp blocked_assignment?(assignment) do
    nonterminal_assignment?(assignment) and
      (phase_name(field_value(assignment, :phase)) == "waiting" or
         not is_nil(safe_text(field_value(assignment, :blocked_reason))) or
         field_value(assignment, :dispatch_paused) == true or
         get_in(assignment, [:projection, :status]) == "failed" or
         not owned_assignment?(assignment))
  end

  defp owned_assignment?(assignment) do
    text_value(field_value(field_value(assignment, :ownership) || %{}, :status)) == "owned"
  end

  defp projection_summary(assignments) do
    values = assignments |> Map.values() |> Enum.filter(&nonterminal_assignment?/1)
    errors = projection_errors(values)
    stale = Enum.any?(values, &get_in(&1, [:projection, :stale]))
    pending = Enum.any?(values, &(get_in(&1, [:projection, :status]) == "pending"))
    unknown = Enum.any?(values, &(get_in(&1, [:projection, :status]) == "unknown"))
    status = projection_summary_status(errors, stale, pending, unknown)

    %{status: status, stale: stale, errors: errors}
  end

  defp projection_errors(assignments) do
    assignments
    |> Enum.filter(&(get_in(&1, [:projection, :status]) == "failed"))
    |> Enum.map(fn assignment ->
      %{assignment_id: assignment.assignment_id, error: get_in(assignment, [:projection, :error]) || "Projection failed"}
    end)
  end

  defp projection_summary_status(errors, _stale, _pending, _unknown) when errors != [], do: "failed"
  defp projection_summary_status(_errors, true, _pending, _unknown), do: "stale"
  defp projection_summary_status(_errors, false, true, _unknown), do: "pending"
  defp projection_summary_status(_errors, false, false, true), do: "unknown"
  defp projection_summary_status(_errors, false, false, false), do: "synced"

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

  defp field_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp field_value(_map, _key), do: nil

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
