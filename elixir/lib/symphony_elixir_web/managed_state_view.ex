defmodule SymphonyElixirWeb.ManagedStateView do
  @moduledoc """
  Read-only projections for the managed control-plane state endpoint.

  The control plane remains the source of truth. This module only selects and
  presents records for an authenticated principal; it does not keep runtime
  state and does not mutate the managed journal.
  """

  @terminal_phases ~w(accepted cancelled)
  @summary_report_limit 500

  @type options :: %{
          view: :summary | :detail | :full,
          project_id: String.t() | nil,
          assignment_id: String.t() | nil,
          include_history: boolean()
        }

  @spec parse_params(map()) :: {:ok, options()} | {:error, {atom(), String.t()}}
  def parse_params(params) when is_map(params) do
    with {:ok, view} <- parse_view(value(params, :view)),
         {:ok, project_id} <- parse_identifier(value(params, :project_id), :project_id),
         {:ok, assignment_id} <- parse_identifier(value(params, :assignment_id), :assignment_id),
         {:ok, include_history} <- parse_boolean(value(params, :include_history)) do
      {:ok,
       %{
         view: view,
         project_id: project_id,
         assignment_id: assignment_id,
         include_history: include_history
       }}
    end
  end

  def parse_params(_params), do: {:error, {:params, "query parameters must be an object"}}

  @spec project(map(), map(), map() | options()) :: {:ok, map()} | {:error, term()}
  def project(state, principal, params \\ %{}) when is_map(state) and is_map(principal) do
    with {:ok, options} <- normalize_options(params),
         {:ok, assignments} <- scoped_assignments(state, principal, options) do
      render_view(state, principal, assignments, options, Map.get(options, :runtime_facts, %{}))
    end
  end

  defp normalize_options(%{view: view, project_id: project_id, assignment_id: assignment_id, include_history: include_history} = options)
       when view in [:summary, :detail, :full] and is_boolean(include_history) do
    with {:ok, normalized_project} <- parse_identifier(project_id, :project_id),
         {:ok, normalized_assignment} <- parse_identifier(assignment_id, :assignment_id) do
      {:ok, %{options | project_id: normalized_project, assignment_id: normalized_assignment}}
    end
  end

  defp normalize_options(params) when is_map(params), do: parse_params(params)
  defp normalize_options(_params), do: {:error, {:params, "query parameters must be an object"}}

  defp render_view(state, principal, assignments, %{view: :summary} = options, runtime_facts) do
    {:ok, summary_payload(state, principal, assignments, options, runtime_facts)}
  end

  defp render_view(_state, _principal, _assignments, %{view: :detail, assignment_id: nil}, _runtime_facts) do
    {:error, {:assignment_id, "assignment_id is required for detail view"}}
  end

  defp render_view(state, principal, assignments, %{view: :detail, assignment_id: assignment_id} = options, runtime_facts) do
    assignment = Map.fetch!(assignments, assignment_id)
    {:ok, detail_payload(state, principal, assignment, options, runtime_facts)}
  end

  defp render_view(state, principal, assignments, %{view: :full} = options, runtime_facts) do
    {:ok, full_payload(state, principal, assignments, options, runtime_facts)}
  end

  defp summary_payload(state, principal, assignments, options, runtime_facts) do
    metadata(state, principal, runtime_facts)
    |> Map.merge(%{
      view: "summary",
      projects: summary_projects(state, assignments, options),
      assignments: summary_assignments(assignments, state, options, runtime_facts),
      counts: assignment_counts(assignments),
      history_included: options.include_history
    })
  end

  defp detail_payload(state, principal, assignment, options, runtime_facts) do
    metadata(state, principal, runtime_facts)
    |> Map.merge(%{
      view: "detail",
      project: detail_project(state, assignment),
      assignment: detail_assignment(assignment, state, runtime_facts),
      history_included: options.include_history
    })
  end

  defp full_payload(state, principal, assignments, options, runtime_facts) do
    state
    |> Map.put(:principal, principal_payload(principal))
    |> Map.put(:view, "full")
    |> Map.put(:usage, usage_payload(Map.get(state, :usage)))
    |> Map.put(:diagnostics, diagnostics_payload(state, runtime_facts))
    |> Map.put(:assignments, full_assignments(assignments))
    |> maybe_filter_projects(options.project_id, state)
  end

  defp full_assignments(assignments) when is_map(assignments) do
    Map.new(assignments, fn {id, assignment} ->
      if is_map(assignment) and Map.has_key?(assignment, :usage) do
        {id, Map.put(assignment, :usage, usage_payload(Map.get(assignment, :usage)))}
      else
        {id, assignment}
      end
    end)
  end

  defp maybe_filter_projects(state, nil, _original), do: state

  defp maybe_filter_projects(state, project_id, original) do
    projects = Map.get(original, :projects, %{})

    Map.put(
      state,
      :projects,
      projects
      |> project_entries()
      |> Enum.filter(fn {id, project} -> project_id_of(project, nil) == project_id or id == project_id end)
      |> Map.new()
    )
  end

  defp metadata(state, principal, runtime_facts) do
    usage = usage_payload(Map.get(state, :usage))

    %{
      status: "available",
      revision: integer_or_default(Map.get(state, :revision), Map.get(state, :control_revision, 0)),
      control_revision: integer_or_default(Map.get(state, :control_revision), 0),
      cursor: integer_or_default(Map.get(state, :cursor), Map.get(state, :event_cursor, 0)),
      event_cursor: integer_or_default(Map.get(state, :event_cursor), Map.get(state, :cursor, 0)),
      version: Map.get(state, :version, 2),
      principal: principal_payload(principal),
      disabled: Map.get(state, :disabled, false) == true,
      paused: Map.get(state, :paused, false) == true,
      usage_limit_tokens: integer_or_nil(Map.get(state, :usage_limit_tokens)),
      usage: usage,
      diagnostics: diagnostics_payload(state, runtime_facts)
    }
  end

  defp diagnostics_payload(state, runtime_facts) do
    limits = concurrency_limits(state, runtime_facts)
    %{concurrency: limits}
  end

  defp concurrency_limits(state, runtime_facts) do
    runtime = Map.get(state, :runtime, %{})

    limits = %{
      global:
        positive_integer(Map.get(runtime_facts, :max_concurrent_agents)) ||
          positive_integer(Map.get(state, :max_concurrent_agents)) ||
          positive_integer(field(runtime, :max_concurrent_agents)),
      by_state:
        safe_limits(
          Map.get(runtime_facts, :max_concurrent_agents_by_state) ||
            Map.get(state, :max_concurrent_agents_by_state) ||
            field(runtime, :max_concurrent_agents_by_state)
        )
    }

    Map.put(limits, :fallback, limits.global)
  end

  defp safe_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {key, value}, acc ->
      case {text_value(key), positive_integer(value)} do
        {state, limit} when is_binary(state) and is_integer(limit) -> Map.put(acc, state, limit)
        _ -> acc
      end
    end)
  end

  defp safe_limits(_limits), do: %{}

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp scoped_assignments(state, principal, options) do
    all = state |> Map.get(:assignments, %{}) |> assignment_entries()

    selected =
      all
      |> Enum.filter(fn {id, assignment} ->
        matches_project?(assignment, options.project_id) and
          matches_assignment?(id, options.assignment_id) and
          authorized_assignment?(assignment, principal, options)
      end)
      |> Map.new()

    if is_binary(options.assignment_id) and not Map.has_key?(selected, options.assignment_id) do
      {:error, {:assignment_not_found, options.assignment_id}}
    else
      {:ok, filter_history(selected, principal, options)}
    end
  end

  defp authorized_assignment?(_assignment, %{role: role}, _options) when role in [:operator, "operator"], do: true

  defp authorized_assignment?(assignment, principal, %{project_id: project_id}) when is_binary(project_id) do
    # An explicit project is an inspection scope. Existing managed auth is the
    # authority for this read endpoint; it does not claim a new project ACL.
    is_map(assignment) and
      (ownership_pm_id(assignment) == principal_id(principal) or
         project_id_of(assignment, nil) == project_id)
  end

  defp authorized_assignment?(assignment, principal, _options) do
    ownership_pm_id(assignment) == principal_id(principal)
  end

  defp matches_project?(_assignment, nil), do: true
  defp matches_project?(assignment, project_id), do: project_id_of(assignment, nil) == project_id

  defp matches_assignment?(_id, nil), do: true
  defp matches_assignment?(id, assignment_id), do: id == assignment_id

  defp filter_history(assignments, _principal, %{include_history: true}), do: assignments

  defp filter_history(assignments, _principal, %{assignment_id: assignment_id}) when is_binary(assignment_id),
    do: assignments

  defp filter_history(assignments, %{role: role} = principal, _options) when role in [:pm, "pm"] do
    active_pm_ids =
      assignments
      |> Enum.reject(fn {_id, assignment} -> terminal_assignment?(assignment) end)
      |> Enum.map(fn {_id, assignment} -> ownership_pm_id(assignment) end)
      |> MapSet.new()

    caller_id = principal_id(principal)

    assignments
    |> Enum.filter(fn {_id, assignment} ->
      not terminal_assignment?(assignment) or
        ownership_pm_id(assignment) == caller_id or
        MapSet.member?(active_pm_ids, ownership_pm_id(assignment))
    end)
    |> Map.new()
  end

  defp filter_history(assignments, _principal, _options) do
    active_pm_ids =
      assignments
      |> Enum.reject(fn {_id, assignment} -> terminal_assignment?(assignment) end)
      |> Enum.map(fn {_id, assignment} -> ownership_pm_id(assignment) end)
      |> MapSet.new()

    assignments
    |> Enum.filter(fn {_id, assignment} ->
      not terminal_assignment?(assignment) or MapSet.member?(active_pm_ids, ownership_pm_id(assignment))
    end)
    |> Map.new()
  end

  defp summary_projects(state, assignments, %{project_id: explicit_project}) do
    projects = project_entries(Map.get(state, :projects, %{}))

    projects
    |> Enum.filter(fn {id, _project} ->
      (is_nil(explicit_project) or id == explicit_project) and
        (explicit_project != nil or
           Enum.any?(assignments, fn {_assignment_id, assignment} -> project_id_of(assignment, nil) == id end))
    end)
    |> Enum.map(fn {id, project} -> {id, project_payload(project, id)} end)
    |> Map.new()
  end

  defp summary_assignments(assignments, state, options, runtime_facts) do
    assignments
    |> Enum.map(fn {id, assignment} -> {id, summary_assignment(assignment, id, state, options, runtime_facts)} end)
    |> Map.new()
  end

  defp summary_assignment(assignment, id, state, _options, runtime_facts) do
    compact(%{
      assignment_id: id,
      project_id: project_id_of(assignment, nil),
      repository: text_value(field(assignment, :repository)),
      issue_number: scalar(field(assignment, :issue_number)),
      issue_url: issue_url(assignment),
      title: text_value(field(assignment, :title)),
      phase: phase_name(field(assignment, :phase)),
      status: status_name(assignment),
      board_state: text_value(field(assignment, :board_state)),
      ownership: ownership_payload(assignment),
      dispatch_paused: field(assignment, :dispatch_paused) == true,
      stop_pending: field(assignment, :stop_pending) == true,
      wait_reason: wait_reason(assignment, state, runtime_facts),
      worker: worker_payload(assignment),
      route: route_payload(assignment),
      last_report: report_summary(field(assignment, :last_report)),
      peer_report_refs: peer_report_refs(assignment),
      report_id: report_id(assignment),
      report_source: report_source(assignment),
      attempt: attempt_summary(assignment),
      usage: usage_payload(field(assignment, :usage)),
      started_at: timestamp(field(assignment, :started_at)),
      updated_at: timestamp(field(assignment, :updated_at))
    })
  end

  defp assignment_counts(assignments) do
    values = Map.values(assignments)

    %{
      total: length(values),
      running: Enum.count(values, &worker_active?/1),
      queued: Enum.count(values, &(phase_name(field(&1, :phase)) in ["bound", "ready"])),
      review: Enum.count(values, &(phase_name(field(&1, :phase)) in ["review", "review_pending"])),
      waiting: Enum.count(values, &(phase_name(field(&1, :phase)) == "waiting")),
      terminal: Enum.count(values, &terminal_assignment?/1)
    }
  end

  defp detail_assignment(assignment, state, runtime_facts) do
    assignment
    |> Map.put(:assignment_id, field(assignment, :assignment_id) || key_for_assignment(assignment))
    |> Map.put(:project_id, project_id_of(assignment, nil))
    |> Map.put(:wait_reason, wait_reason(assignment, state, runtime_facts))
    |> Map.put(:peer_report_refs, peer_report_refs(assignment))
    |> Map.put(:reports, field(assignment, :reports) || %{})
    |> Map.put(:last_report, field(assignment, :last_report))
    |> Map.put(:attempt, field(assignment, :attempt))
    |> Map.put(:usage, field(assignment, :usage))
  end

  defp detail_project(state, assignment) do
    project_id = project_id_of(assignment, nil)

    state
    |> Map.get(:projects, %{})
    |> project_entries()
    |> Enum.find_value(fn {id, project} ->
      if id == project_id, do: project_payload(project, id)
    end)
  end

  defp project_entries(projects) when is_map(projects), do: Enum.map(projects, fn {key, value} -> {text_value(key) || key, value} end)
  defp project_entries(_projects), do: []

  defp assignment_entries(assignments) when is_map(assignments) do
    assignments
    |> Enum.map(fn {key, value} -> {text_value(key) || key, value} end)
    |> Enum.filter(fn {_key, value} -> is_map(value) end)
  end

  defp assignment_entries(_assignments), do: []

  defp project_payload(project, id) when is_map(project) do
    compact(%{
      project_id: project_id_of(project, id),
      project_number: scalar(field(project, :project_number)),
      status_field_id: text_value(field(project, :status_field_id)),
      status_field_name: text_value(field(project, :status_field_name)),
      owner: text_value(field(project, :owner)),
      owner_type: text_value(field(project, :owner_type)),
      repositories: scalar_list(field(project, :repositories)),
      status_options: scalar_map(field(project, :status_options)),
      revision: scalar(field(project, :revision)),
      dispatch_paused: field(project, :dispatch_paused) == true
    })
  end

  defp project_payload(_project, id), do: %{project_id: id}

  defp ownership_payload(assignment) do
    ownership = field(assignment, :ownership) || %{}

    %{
      pm_id: text_value(field(ownership, :pm_id)),
      status: status_name(ownership, "unassigned"),
      ownership_revision: integer_or_nil(field(ownership, :ownership_revision))
    }
  end

  defp worker_payload(assignment) do
    compact(%{
      id: text_value(field(assignment, :worker_id)),
      host: text_value(field(assignment, :worker_host)),
      active: worker_active?(assignment)
    })
  end

  defp worker_active?(assignment), do: not terminal_assignment?(assignment) and field(assignment, :worker_active) == true

  defp route_payload(assignment) do
    route = field(assignment, :route) || %{}

    compact(%{
      model: text_value(field(route, :model) || field(assignment, :turn_model)),
      effort: text_value(field(route, :effort) || field(assignment, :turn_effort)),
      source: if(worker_active?(assignment), do: "running", else: "configured")
    })
  end

  defp attempt_summary(assignment) do
    attempt = field(assignment, :attempt) || %{}
    attempt_id = text_value(field(attempt, :attempt_id) || field(attempt, :id) || field(assignment, :attempt_id))

    compact(%{
      attempt_id: attempt_id,
      generation: scalar(field(attempt, :generation) || field(assignment, :generation)),
      revision: scalar(field(attempt, :revision) || field(assignment, :revision)),
      status: text_value(field(attempt, :status)),
      started_at: timestamp(field(attempt, :started_at)),
      completed_at: timestamp(field(attempt, :completed_at))
    })
  end

  defp report_summary(nil), do: nil

  defp report_summary(report) when is_map(report) do
    compact(%{
      report_id: report_id_from(report),
      kind: text_value(field(report, :kind)),
      summary: report |> field(:summary) |> report_text() |> String.slice(0, @summary_report_limit),
      source: text_value(field(report, :source) || field(report, :source_id)),
      source_assignment_id: text_value(field(report, :source_assignment_id)),
      source_attempt_id: text_value(field(report, :source_attempt_id)),
      attempt_id: text_value(field(report, :attempt_id)),
      attempt: scalar(field(report, :attempt))
    })
  end

  defp report_summary(_report), do: nil

  defp report_id(assignment), do: report_id_from(field(assignment, :last_report)) || text_value(field(assignment, :report_id))
  defp report_source(assignment), do: text_value(field(assignment, :report_source) || field(assignment, :report_source_id))

  defp report_id_from(report) when is_map(report), do: text_value(field(report, :report_id) || field(report, :id))
  defp report_id_from(_report), do: nil

  defp peer_report_refs(assignment) do
    assignment
    |> field(:review_feedback)
    |> field(:peer_report_refs)
    |> case do
      nil -> field(assignment, :peer_report_refs)
      refs -> refs
    end
    |> peer_report_refs_payload()
  end

  defp peer_report_refs_payload(refs) when is_list(refs) do
    refs
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn ref ->
      compact(%{
        source_assignment_id: text_value(field(ref, :source_assignment_id)),
        source_attempt_id: text_value(field(ref, :source_attempt_id)),
        report_id: text_value(field(ref, :report_id))
      })
    end)
    |> Enum.reject(&(map_size(&1) == 0))
  end

  defp peer_report_refs_payload(_refs), do: []

  @spec wait_reason(map(), map(), map()) :: String.t() | nil
  def wait_reason(assignment, state, runtime_facts)
      when is_map(assignment) and is_map(state) and is_map(runtime_facts) do
    if phase_name(field(assignment, :phase)) in ["ready", "bound"] do
      ready_wait_reason(assignment, state, runtime_facts)
    end
  end

  defp ready_wait_reason(assignment, state, runtime_facts) do
    case service_wait_reason(assignment, state) do
      nil ->
        case assignment_wait_reason(assignment) do
          nil -> work_wait_reason(assignment, state, runtime_facts)
          reason -> reason
        end

      reason ->
        reason
    end
  end

  defp service_wait_reason(assignment, state) do
    cond do
      Map.get(state, :disabled, false) == true -> "managed_mode_disabled"
      Map.get(state, :paused, false) == true -> "service_paused"
      project_paused?(assignment, state) -> "project_paused"
      true -> nil
    end
  end

  defp assignment_wait_reason(assignment) do
    cond do
      field(assignment, :dispatch_paused) == true -> "assignment_paused"
      field(assignment, :stop_pending) == true -> "stop_pending"
      true -> nil
    end
  end

  defp work_wait_reason(assignment, state, runtime_facts) do
    cond do
      usage_accounting_unavailable?(state) -> "usage_accounting_unavailable"
      field(state[:usage], :cap_reached) == true -> "usage_limit_reached"
      dependencies_blocked?(assignment, state) -> "dependencies_not_accepted"
      capacity_full?(state, runtime_facts) -> "concurrency_limit"
      true -> "ready"
    end
  end

  defp usage_accounting_unavailable?(state) do
    is_integer(state[:usage_limit_tokens]) and state[:usage_limit_tokens] > 0 and
      field(state[:usage], :accounting_status) in [:unavailable, "unavailable"]
  end

  defp dependencies_blocked?(assignment, state) do
    dependencies = field(assignment, :dependencies)

    is_list(dependencies) and
      Enum.any?(dependencies, fn dependency ->
        dependency_id = text_value(dependency) || text_value(field(dependency, :assignment_id))

        case Map.get(Map.get(state, :assignments, %{}), dependency_id) do
          dep when is_map(dep) -> phase_name(field(dep, :phase)) != "accepted"
          _ -> true
        end
      end)
  end

  defp capacity_full?(state, runtime_facts) do
    max_agents = capacity_limit(state, runtime_facts)
    running = running_count(state, runtime_facts)
    is_integer(max_agents) and is_integer(running) and running >= max_agents
  end

  defp capacity_limit(state, runtime_facts) do
    integer_value(Map.get(runtime_facts, :max_concurrent_agents)) ||
      integer_value(Map.get(state, :max_concurrent_agents)) ||
      integer_value(field(Map.get(state, :runtime), :max_concurrent_agents)) ||
      integer_value(field(Map.get(state, :runtime), :max_agents))
  end

  defp running_count(state, runtime_facts) do
    integer_value(Map.get(runtime_facts, :running_count)) ||
      runtime_running_count(Map.get(runtime_facts, :running)) ||
      state_running_count(state)
  end

  defp state_running_count(state) do
    case Map.get(state, :running) do
      value when is_map(value) -> map_size(value)
      value when is_list(value) -> length(value)
      _ -> integer_value(field(Map.get(state, :runtime), :running_count))
    end
  end

  defp runtime_running_count(value) when is_map(value), do: map_size(value)
  defp runtime_running_count(value) when is_list(value), do: length(value)
  defp runtime_running_count(_value), do: nil

  defp project_paused?(assignment, state) do
    project_id = project_id_of(assignment, nil)

    state
    |> Map.get(:projects, %{})
    |> project_entries()
    |> Enum.any?(fn {id, project} -> id == project_id and field(project, :dispatch_paused) == true end)
  end

  defp phase_name(value) do
    case text_value(value) do
      nil -> "unknown"
      phase -> String.downcase(phase)
    end
  end

  defp terminal_assignment?(assignment), do: phase_name(field(assignment, :phase)) in @terminal_phases

  defp status_name(value, default \\ nil)

  defp status_name(map, default) when is_map(map) do
    text_value(field(map, :status) || field(map, :phase) || field(map, :board_state)) || default || "unknown"
  end

  defp status_name(value, default) do
    text_value(value) || default || "unknown"
  end

  defp ownership_pm_id(assignment), do: text_value(field(field(assignment, :ownership) || %{}, :pm_id))
  defp principal_id(principal), do: text_value(field(principal, :principal_id))

  defp principal_payload(principal) do
    compact(%{
      principal_id: text_value(field(principal, :principal_id)),
      role: text_value(field(principal, :role)),
      project_scope: text_value(field(principal, :project_scope))
    })
  end

  defp issue_url(assignment) do
    repository = text_value(field(assignment, :repository))
    number = field(assignment, :issue_number)

    if is_binary(repository) and is_integer(number) and number > 0 do
      "https://github.com/#{repository}/issues/#{number}"
    end
  end

  defp usage_payload(nil), do: %{}

  defp usage_payload(usage) when is_map(usage) do
    status = usage_accounting_status(usage)

    projected =
      usage
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        key = text_value(key)

        cond do
          is_nil(key) or key == "historical_raw_tokens" ->
            acc

          key == "accounting_status" ->
            Map.put(acc, key, status)

          true ->
            put_usage_value(acc, key, value)
        end
      end)

    raw_history = Map.get(usage, :historical_raw_tokens, Map.get(usage, "historical_raw_tokens"))

    case historical_tokens_payload(raw_history) do
      values when is_map(values) and map_size(values) > 0 and status in ["unavailable", "unreliable"] ->
        Map.put(projected, "historical_raw_tokens", %{diagnostic: status, valid_spend: false, values: values})

      _ ->
        projected
    end
  end

  defp usage_payload(_usage), do: %{}

  defp put_usage_value(acc, key, value) do
    case safe_usage_value(value) do
      {:ok, safe} -> Map.put(acc, key, safe)
      :error -> acc
    end
  end

  defp usage_accounting_status(usage) do
    case text_value(Map.get(usage, :accounting_status)) do
      status when status in ["known", "unavailable", "unreliable"] ->
        status

      _ ->
        raw = Map.get(usage, :historical_raw_tokens, Map.get(usage, "historical_raw_tokens"))
        if(is_map(raw), do: "unavailable", else: "known")
    end
  end

  defp safe_usage_value(value) when is_integer(value) or is_float(value) or is_boolean(value) or is_binary(value),
    do: {:ok, value}

  defp safe_usage_value(nil), do: {:ok, nil}
  defp safe_usage_value(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp safe_usage_value(_value), do: :error

  defp historical_tokens_payload(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {key, number}, acc ->
      key = text_value(key)

      if is_nil(key) do
        acc
      else
        put_historical_token(acc, key, number)
      end
    end)
  end

  defp historical_tokens_payload(_value), do: %{}

  defp put_historical_token(acc, key, value) when is_integer(value) or is_float(value),
    do: Map.put(acc, key, value)

  defp put_historical_token(acc, _key, _value), do: acc

  defp scalar(value) when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value), do: value
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(_value), do: nil

  defp scalar_list(values) when is_list(values), do: values |> Enum.map(&scalar/1) |> Enum.reject(&is_nil/1)
  defp scalar_list(_values), do: []

  defp scalar_map(values) when is_map(values) do
    values
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case {scalar(key), scalar(value)} do
        {nil, _} -> acc
        {_key, nil} -> acc
        {key, value} -> Map.put(acc, key, value)
      end
    end)
  end

  defp scalar_map(_values), do: %{}

  defp report_text(value) when is_binary(value), do: value
  defp report_text(value) when is_atom(value), do: Atom.to_string(value)
  defp report_text(value) when is_integer(value), do: Integer.to_string(value)
  defp report_text(value) when is_float(value), do: Float.to_string(value)
  defp report_text(_value), do: ""

  defp text_value(nil), do: nil

  defp text_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp text_value(value) when is_atom(value), do: Atom.to_string(value)
  defp text_value(value) when is_integer(value), do: Integer.to_string(value)
  defp text_value(_value), do: nil

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> DateTime.to_iso8601(parsed)
      _ -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp integer_or_default(value, _fallback) when is_integer(value), do: value
  defp integer_or_default(_value, fallback), do: fallback

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: nil

  defp project_id_of(map, fallback) when is_map(map), do: text_value(field(map, :project_id)) || fallback
  defp project_id_of(_map, fallback), do: fallback

  defp key_for_assignment(assignment), do: text_value(field(assignment, :assignment_id))

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp parse_view(nil), do: {:ok, :summary}
  defp parse_view(value) when value in [:summary, :detail, :full], do: {:ok, value}

  defp parse_view(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "summary" -> {:ok, :summary}
      "detail" -> {:ok, :detail}
      "full" -> {:ok, :full}
      _ -> {:error, {:view, "view must be one of summary, detail, or full"}}
    end
  end

  defp parse_view(_value), do: {:error, {:view, "view must be one of summary, detail, or full"}}

  defp parse_identifier(nil, _field), do: {:ok, nil}

  defp parse_identifier(value, field) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, {field, "#{field} must not be empty"}}, else: {:ok, value}
  end

  defp parse_identifier(_value, field), do: {:error, {field, "#{field} must be a string"}}

  defp parse_boolean(nil), do: {:ok, false}
  defp parse_boolean(value) when is_boolean(value), do: {:ok, value}

  defp parse_boolean(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, {:include_history, "include_history must be true or false"}}
    end
  end

  defp parse_boolean(_value), do: {:error, {:include_history, "include_history must be true or false"}}

  defp compact(map), do: Enum.reject(map, fn {_key, value} -> is_nil(value) end) |> Map.new()
end
