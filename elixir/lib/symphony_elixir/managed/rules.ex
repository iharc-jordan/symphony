defmodule SymphonyElixir.Managed.Rules do
  @moduledoc """
  Deterministic lifecycle and control rules for the managed scheduler.

  This module has no process or provider side effects. The Orchestrator applies
  the returned state and persists it through the managed journal.
  """

  @version 1
  @operations ~w(bind_project enroll revise pause resume interrupt cancel review)a
  @terminal_phases [:accepted, :cancelled]
  @active_phases [:ready, :active, :waiting, :review]
  @allowed_routes %{
    "gpt-5.6-luna" => ~w(xhigh max),
    "gpt-5.6-terra" => ~w(xhigh max)
  }
  @default_route %{model: "gpt-5.6-luna", effort: "xhigh"}
  @revision_change_keys ~w(base_commit route resources dependencies requirements requirements_fingerprint requirements_revision escalation_reason)a

  @type state :: map()
  @type envelope :: map()
  @type result :: {:ok, state(), map()} | {:duplicate, map()} | {:error, atom(), map()}

  @spec version() :: pos_integer()
  def version, do: @version

  @spec allowed_operations() :: [atom()]
  def allowed_operations, do: @operations

  @spec new(keyword()) :: state()
  def new(opts \\ []) do
    %{
      version: @version,
      control_revision: Keyword.get(opts, :control_revision, 0),
      event_cursor: Keyword.get(opts, :event_cursor, 0),
      paused: Keyword.get(opts, :paused, false),
      disabled: Keyword.get(opts, :disabled, false),
      binding: Keyword.get(opts, :binding),
      assignments: Keyword.get(opts, :assignments, %{}),
      requests: Keyword.get(opts, :requests, %{}),
      events: Keyword.get(opts, :events, []),
      external_reconciliations: Keyword.get(opts, :external_reconciliations, %{}),
      review_intents: Keyword.get(opts, :review_intents, %{}),
      effect_intents: Keyword.get(opts, :effect_intents, %{}),
      usage:
        Keyword.get(opts, :usage, %{
          baseline_tokens: Keyword.get(opts, :baseline_tokens, 0),
          cumulative_tokens: Keyword.get(opts, :cumulative_tokens, 0),
          inflight_tokens: 0,
          overshoot_tokens: 0,
          cap_reached: false
        }),
      usage_limit_tokens: Keyword.get(opts, :usage_limit_tokens)
    }
  end

  @spec snapshot(state()) :: map()
  def snapshot(state) when is_map(state) do
    state
    |> Map.drop([:requests, :review_intents, :effect_intents])
    |> Map.put(:assignments, assignment_snapshots(Map.get(state, :assignments, %{})))
    |> Map.put(:revision, Map.get(state, :control_revision, 0))
    |> Map.put(:cursor, Map.get(state, :event_cursor, 0))
  end

  @spec canonical_input(envelope()) :: binary()
  def canonical_input(envelope) when is_map(envelope) do
    envelope
    |> drop_issue_content()
    |> canonical_term()
    |> :erlang.term_to_binary()
  end

  @spec apply(state(), envelope()) :: result()
  @spec apply(state(), envelope(), map()) :: result()
  def apply(state, envelope, context \\ %{}) when is_map(state) and is_map(envelope) do
    with {:ok, normalized} <- normalize_envelope(envelope),
         :ok <- validate_request_id(normalized.request_id),
         {:ok, operation} <- normalize_operation(normalized.operation),
         {:ok, args} <- normalize_args(normalized.args) do
      normalized = %{normalized | operation: operation, args: args}
      canonical = canonical_input(normalized)

      case Map.get(state.requests, normalized.request_id) do
        %{canonical: ^canonical, response: response} ->
          {:duplicate, response}

        %{canonical: _other} ->
          {:error, :request_id_conflict, %{request_id: normalized.request_id}}

        nil ->
          apply_new(state, normalized, canonical, context)
      end
    else
      {:error, code, details} -> {:error, code, details}
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  @doc false
  @spec prepare_review(state(), envelope()) ::
          {:ok, map()} | {:duplicate, map()} | {:error, atom(), map()}
  def prepare_review(state, envelope) when is_map(state) and is_map(envelope) do
    with {:ok, normalized} <- normalize_envelope(envelope),
         :ok <- validate_request_id(normalized.request_id),
         {:ok, :review} <- normalize_operation(normalized.operation),
         {:ok, args} <- normalize_args(normalized.args) do
      normalized = %{normalized | operation: :review, args: args}
      canonical = canonical_input(normalized)

      case Map.get(state.requests, normalized.request_id) do
        %{canonical: ^canonical, response: response} ->
          {:duplicate, response}

        %{canonical: _other} ->
          {:error, :request_id_conflict, %{request_id: normalized.request_id}}

        nil ->
          review_intent(state, normalized, canonical, args)
      end
    else
      {:error, code, details} -> {:error, code, details}
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  defp review_intent(state, normalized, canonical, args) do
    assignment_id = text_value(args, :assignment_id)
    disposition = args |> Map.get(:disposition, "accepted") |> phase()

    with :ok <- present(assignment_id, :assignment_id),
         {:ok, assignment} <- fetch_assignment(state, assignment_id),
         :ok <- expected_revision(state, args, {:assignment, assignment_id}),
         :ok <- validate_review_intent(assignment, disposition, args) do
      {:ok,
       %{
         request: normalized,
         canonical: canonical,
         assignment: assignment,
         disposition: disposition,
         requires_effects: disposition == :accepted
       }}
    end
  end

  defp validate_review_intent(assignment, :accepted, args) do
    with :ok <- phase_is(assignment.phase, :review) do
      evidence_present(Map.get(args, :evidence, []))
    end
  end

  defp validate_review_intent(_assignment, disposition, args) when disposition in [:waiting, :rework, :blocked] do
    present(text_value(args, :reason), :reason)
  end

  defp validate_review_intent(_assignment, disposition, _args), do: {:error, :invalid_disposition, %{disposition: disposition}}

  @spec expected_revision(state(), map(), :global | {:assignment, String.t()}) ::
          :ok | {:error, atom(), map()}
  def expected_revision(state, args, scope) when is_map(state) and is_map(args) do
    expected = Map.get(args, :expected_revision)

    actual =
      case scope do
        :global -> Map.get(state, :control_revision, 0)
        {:assignment, id} -> get_in(state, [:assignments, id, :revision])
      end

    cond do
      not is_integer(expected) -> {:error, :expected_revision_required, %{}}
      expected != actual -> {:error, :stale_revision, %{expected: expected, actual: actual}}
      true -> :ok
    end
  end

  @spec validate_route(map()) :: :ok | {:error, atom(), map()}
  def validate_route(route), do: validate_route(route, nil)

  @spec validate_route(map(), String.t() | nil) :: :ok | {:error, atom(), map()}
  def validate_route(route, escalation_reason) when is_map(route) do
    model = route |> Map.get(:model, Map.get(route, "model")) |> normalize_text()
    effort = route |> Map.get(:effort, Map.get(route, "effort")) |> normalize_text()
    default? = model == @default_route.model and effort == @default_route.effort
    reason = normalize_text(escalation_reason)

    cond do
      model not in Map.keys(@allowed_routes) or effort not in Map.get(@allowed_routes, model, []) ->
        {:error, :invalid_route, %{model: model, effort: effort}}

      not default? and is_nil(reason) ->
        {:error, :route_escalation_reason_required, %{model: model, effort: effort}}

      true ->
        :ok
    end
  end

  def validate_route(_route, _escalation_reason), do: {:error, :invalid_route, %{}}

  @spec validate_transition(atom() | String.t(), atom() | String.t()) ::
          :ok | {:error, atom(), map()}
  def validate_transition(from, to) do
    from = phase(from)
    to = phase(to)

    if to in transition_targets(from) do
      :ok
    else
      {:error, :invalid_phase_transition, %{from: from, to: to}}
    end
  end

  @spec phase(atom() | String.t()) :: atom()
  @known_phases ~w(idle bound ready active waiting review rework accepted cancelled)a
  @phase_aliases %{
    "idle" => :idle,
    "bound" => :bound,
    "ready" => :ready,
    "queued" => :ready,
    "active" => :active,
    "in_progress" => :active,
    "in-progress" => :active,
    "waiting" => :waiting,
    "blocked" => :waiting,
    "rework" => :rework,
    "review" => :review,
    "in_review" => :review,
    "in-review" => :review,
    "accepted" => :accepted,
    "cancelled" => :cancelled,
    "canceled" => :cancelled
  }

  def phase(value) when is_atom(value) and value in @known_phases, do: value
  def phase(value) when is_atom(value), do: :unknown
  def phase(value) when is_binary(value), do: Map.get(@phase_aliases, value |> String.trim() |> String.downcase(), :unknown)
  def phase(_value), do: :unknown

  defp apply_new(state, %{operation: :bind_project, args: args} = request, canonical, _context),
    do: apply_binding(state, request, canonical, args)

  defp apply_new(state, %{operation: :enroll, args: args} = request, canonical, _context),
    do: apply_enrollment(state, request, canonical, args)

  defp apply_new(state, %{operation: :revise, args: args} = request, canonical, context),
    do: apply_revision(state, request, canonical, args, context)

  defp apply_new(state, %{operation: operation, args: args} = request, canonical, _context)
       when operation in [:pause, :resume] do
    with :ok <- expected_revision(state, args, :global) do
      paused = operation == :pause
      disabled = if paused, do: Map.get(args, :disable, false) == true, else: false
      response = %{operation: operation, revision: state.control_revision + 1, paused: paused, disabled: disabled}
      commit(state, request, canonical, response, %{paused: paused, disabled: disabled})
    end
  end

  defp apply_new(state, %{operation: operation, args: args} = request, canonical, context)
       when operation in [:interrupt, :cancel, :review] do
    assignment_id = text_value(args, :assignment_id)

    with :ok <- present(assignment_id, :assignment_id),
         {:ok, assignment} <- fetch_assignment(state, assignment_id),
         :ok <- expected_revision(state, args, {:assignment, assignment_id}),
         {:ok, next_phase, patch, response} <- assignment_operation(operation, assignment, args, state, context),
         :ok <- validate_transition(assignment.phase, next_phase) do
      updated =
        assignment
        |> Map.merge(Map.put(patch, :phase, next_phase))
        |> Map.update(:revision, 1, &(&1 + 1))

      assignments = Map.put(state.assignments, assignment_id, updated)

      commit(
        state,
        request,
        canonical,
        Map.merge(response, %{assignment_id: assignment_id, revision: updated.revision, phase: next_phase}),
        %{assignments: assignments}
      )
    end
  end

  defp apply_new(_state, %{operation: operation}, _canonical, _context) do
    {:error, :unsupported_operation, %{operation: operation}}
  end

  defp apply_binding(state, request, canonical, args) do
    with :ok <- expected_revision(state, args, :global),
         {:ok, binding} <- binding_from_args(args),
         :ok <- binding_rebind_allowed?(state, binding) do
      response = %{operation: :bind_project, binding: binding, revision: state.control_revision + 1}
      commit(state, request, canonical, response, %{binding: binding})
    end
  end

  # A project binding is an authority boundary. Replacing it while any
  # assignment is still owned by the service could make the old worker mutate
  # a different project after restart.
  defp binding_rebind_allowed?(%{binding: nil}, _binding), do: :ok

  defp binding_rebind_allowed?(state, binding) do
    if state.binding == binding do
      :ok
    else
      binding_rebind_conflict(state)
    end
  end

  defp binding_rebind_conflict(state) do
    case Enum.find(state.assignments, fn {_id, assignment} ->
           is_map(assignment) and phase(assignment[:phase]) not in @terminal_phases
         end) do
      nil ->
        :ok

      {assignment_id, assignment} ->
        {:error, :binding_in_use, %{assignment_id: assignment_id, phase: phase(assignment[:phase])}}
    end
  end

  defp apply_enrollment(state, request, canonical, args) do
    with :ok <- expected_revision(state, args, :global),
         :ok <- binding_present(state),
         {:ok, assignment} <- assignment_from_args(args),
         :ok <- repository_in_binding(state.binding, assignment.repository),
         :ok <- duplicate_identity_free?(state, assignment),
         :ok <- resources_free?(state, assignment.resources) do
      assignment = Map.put(assignment, :revision, 1)
      assignments = Map.put(state.assignments, assignment.assignment_id, assignment)

      response = %{
        operation: :enroll,
        assignment_id: assignment.assignment_id,
        revision: 1,
        phase: assignment.phase,
        control_revision: state.control_revision + 1
      }

      commit(state, request, canonical, response, %{assignments: assignments})
    end
  end

  defp apply_revision(state, request, canonical, args, context) do
    assignment_id = text_value(args, :assignment_id)

    with :ok <- present(assignment_id, :assignment_id),
         {:ok, assignment} <- fetch_assignment(state, assignment_id),
         :ok <- expected_revision(state, args, {:assignment, assignment_id}),
         :ok <- stop_reconciled_for_revision(assignment, context),
         {:ok, changes} <- revision_changes(args),
         {:ok, route} <- maybe_route(changes),
         {:ok, revised} <- revise_assignment(assignment, changes, route),
         :ok <- duplicate_identity_free_after_revision?(state, assignment_id, revised),
         :ok <- resources_free?(state, revised.resources, assignment_id) do
      assignments = Map.put(state.assignments, assignment_id, revised)
      response = %{operation: :revise, assignment_id: assignment_id, revision: revised.revision, phase: revised.phase}
      commit(state, request, canonical, response, %{assignments: assignments})
    end
  end

  defp assignment_operation(:interrupt, assignment, args, _state, _context) do
    reason = text_value(args, :reason)

    with :ok <- present(reason, :reason),
         :ok <- phase_is(assignment.phase, :active) do
      updates = %{blocked_reason: reason, board_state: :waiting, stop_pending: true}
      response = %{operation: :interrupt, reason: reason}
      {:ok, :waiting, updates, response}
    end
  end

  defp assignment_operation(:cancel, assignment, args, _state, _context) do
    reason = text_value(args, :reason) || "cancelled by operator"

    if assignment.phase in @terminal_phases do
      {:error, :already_terminal, %{phase: assignment.phase}}
    else
      updates = %{disposition_reason: reason, board_state: :cancelled, stop_pending: true}
      response = %{operation: :cancel, reason: reason}
      {:ok, :cancelled, updates, response}
    end
  end

  defp assignment_operation(:review, assignment, args, state, context) do
    disposition = args |> Map.get(:disposition, "accepted") |> phase()
    evidence = Map.get(args, :evidence, [])
    provider_state = context |> Map.get(:provider_state) |> phase()

    cond do
      disposition == :accepted ->
        review_accepted(assignment, provider_state, evidence, state, context)

      disposition in [:waiting, :rework] ->
        review_deferred(disposition, args)

      disposition == :blocked ->
        review_blocked(args)

      true ->
        {:error, :invalid_disposition, %{disposition: disposition}}
    end
  end

  defp review_accepted(assignment, provider_state, evidence, state, context) do
    with :ok <- phase_is(assignment.phase, :review),
         :ok <- provider_phase_is(provider_state, :review),
         :ok <- evidence_present(evidence),
         :ok <- dependencies_accepted(assignment, state),
         :ok <- external_effects_reconciled(context) do
      updates = %{board_state: :accepted, evidence: normalize_evidence(evidence), issue_close: :ok}
      response = %{operation: :review, disposition: :accepted, issue_close: :ok}
      {:ok, :accepted, updates, response}
    end
  end

  defp review_deferred(disposition, args) do
    reason = text_value(args, :reason)

    with :ok <- present(reason, :reason) do
      next_phase = if disposition == :waiting, do: :waiting, else: :ready

      updates = %{board_state: next_phase, disposition_reason: reason}
      response = %{operation: :review, disposition: disposition, reason: reason}
      {:ok, next_phase, updates, response}
    end
  end

  defp review_blocked(args) do
    reason = text_value(args, :reason)

    with :ok <- present(reason, :reason) do
      updates = %{board_state: :waiting, blocked_reason: reason}
      response = %{operation: :review, disposition: :blocked, reason: reason}
      {:ok, :waiting, updates, response}
    end
  end

  defp binding_from_args(args) do
    project = Map.get(args, :project, args)
    project_id = text_value(project, :project_id)
    status_field_id = text_value(project, :status_field_id)
    project_number = number_value(project, :project_number)

    with :ok <- present(project_id, :project_id),
         :ok <- present(status_field_id, :status_field_id),
         :ok <- positive(project_number, :project_number),
         {:ok, options} <- status_options(project),
         {:ok, repositories} <- repository_allowlist(project) do
      {:ok,
       %{
         project_id: project_id,
         project_number: project_number,
         status_field_id: status_field_id,
         status_options: options,
         repositories: repositories
       }}
    end
  end

  defp status_options(project) do
    options = Map.get(project, :status_options, Map.get(project, "status_options"))

    cond do
      is_map(options) and map_size(options) > 0 and valid_status_option_map?(options) -> {:ok, options}
      is_list(options) and options != [] and Enum.all?(options, &valid_status_option?/1) -> {:ok, options}
      true -> {:error, :status_options_required, %{}}
    end
  end

  defp valid_status_option_map?(options) do
    Enum.all?(options, fn {name, id} ->
      is_binary(name) and String.trim(name) != "" and is_binary(id) and String.trim(id) != ""
    end)
  end

  defp valid_status_option?(option) when is_map(option) do
    name = Map.get(option, :name, Map.get(option, "name"))
    id = Map.get(option, :id, Map.get(option, "id"))

    is_binary(name) and String.trim(name) != "" and is_binary(id) and String.trim(id) != ""
  end

  defp valid_status_option?(_option), do: false

  defp repository_allowlist(project) do
    repositories = Map.get(project, :repositories, Map.get(project, "repositories"))

    if is_list(repositories) and repositories != [] and
         Enum.all?(repositories, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, Enum.uniq(Enum.map(repositories, &String.trim/1))}
    else
      {:error, :repository_allowlist_required, %{}}
    end
  end

  defp assignment_from_args(args) do
    assignment_id = text_value(args, :assignment_id)
    repository = text_value(args, :repository)
    issue_number = number_value(args, :issue_number)
    base_commit = text_value(args, :base_commit)

    board_state =
      args
      |> Map.get(:board_state, Map.get(args, "board_state", Map.get(args, :phase, Map.get(args, "phase", "READY"))))
      |> phase()

    route =
      Map.get(args, :route, Map.get(args, "route", %{model: "gpt-5.6-luna", effort: "xhigh"}))

    resources = Map.get(args, :resources, Map.get(args, "resources", []))
    dependencies = Map.get(args, :dependencies, Map.get(args, "dependencies", []))
    project_item_id = text_value(args, :project_item_id) || text_value(args, :native_project_item_id) || assignment_id

    native_issue_id =
      text_value(args, :native_issue_id) ||
        text_value(args, :issue_id) ||
        text_value(args, :issue_node_id)

    native_repository_id =
      text_value(args, :native_repository_id) ||
        text_value(args, :repository_id) ||
        text_value(args, :repository_node_id)

    with :ok <- present(assignment_id, :assignment_id),
         :ok <- present(repository, :repository),
         :ok <- positive(issue_number, :issue_number),
         :ok <- present(base_commit, :base_commit),
         :ok <- phase_is(board_state, :ready),
         escalation_reason <- text_value(args, :escalation_reason),
         :ok <- validate_route(route, escalation_reason),
         :ok <- list_of_binaries(resources, :resources),
         :ok <- list_of_binaries(dependencies, :dependencies),
         {:ok, requirements} <- requirement_metadata(args) do
      {:ok,
       %{
         assignment_id: assignment_id,
         repository: repository,
         issue_number: issue_number,
         base_commit: base_commit,
         phase: :ready,
         board_state: :ready,
         owner: Map.get(args, :owner, Map.get(args, "owner")),
         resources: Enum.uniq(resources),
         dependencies: Enum.uniq(dependencies),
         route: route,
         escalation_reason: escalation_reason,
         project_item_id: project_item_id,
         native_issue_id: native_issue_id,
         native_repository_id: native_repository_id,
         underlying_issue_id: native_issue_id || repository <> "#" <> Integer.to_string(issue_number),
         turn_limit: min(number_value(args, :turn_limit) || 20, 20),
         turns_reserved: 0,
         retry_count: 0,
         enrolled_at: DateTime.utc_now()
       }
       |> Map.merge(requirements)}
    end
  end

  defp repository_in_binding(%{repositories: allowlist}, repository) when is_list(allowlist) do
    if repository in allowlist, do: :ok, else: {:error, :repository_not_allowlisted, %{repository: repository}}
  end

  defp repository_in_binding(_binding, _repository), do: {:error, :project_not_bound, %{}}

  defp revise_assignment(assignment, changes, route) do
    revised =
      assignment
      |> Map.merge(Map.drop(changes, [:assignment_id, :expected_revision]))
      |> Map.put(:revision, assignment.revision + 1)
      |> Map.put(:phase, :ready)
      |> Map.put(:board_state, :ready)
      |> Map.put(:route, route || assignment.route)

    {:ok, revised}
  end

  defp revision_changes(args) do
    changes = Map.get(args, :changes, Map.get(args, "changes", %{}))

    cond do
      not is_map(changes) ->
        {:error, :changes_must_be_map, %{}}

      (unknown = Map.keys(changes) |> Enum.reject(&(&1 in @revision_change_keys))) != [] ->
        {:error, :invalid_argument, %{argument: :changes, fields: unknown}}

      true ->
        validate_and_sanitize_revision_changes(changes)
    end
  end

  defp validate_and_sanitize_revision_changes(changes) do
    requirement_body = Map.get(changes, :requirements)
    fingerprint = text_value(changes, :requirements_fingerprint)
    requirement_revision = Map.get(changes, :requirements_revision)
    escalation_reason = text_value(changes, :escalation_reason)
    base_commit = text_value(changes, :base_commit)
    resources = Map.get(changes, :resources)
    dependencies = Map.get(changes, :dependencies)

    with :ok <- optional_requirements(requirement_body, fingerprint),
         :ok <- optional_text(base_commit, :base_commit),
         :ok <- optional_route(changes),
         :ok <- optional_list_of_binaries(resources, :resources),
         :ok <- optional_list_of_binaries(dependencies, :dependencies),
         :ok <- optional_fingerprint(fingerprint),
         :ok <- optional_requirement_revision(requirement_revision) do
      sanitized =
        changes
        |> Map.take(@revision_change_keys -- [:requirements])
        |> maybe_put(:base_commit, base_commit)
        |> maybe_put(:requirements_fingerprint, fingerprint)
        |> maybe_put(:requirements_revision, requirement_revision)
        |> maybe_put(:escalation_reason, escalation_reason)

      {:ok, sanitized}
    end
  end

  defp optional_requirements(nil, _fingerprint), do: :ok
  defp optional_requirements(body, fingerprint) when is_map(body), do: optional_fingerprint(fingerprint)
  defp optional_requirements(_body, _fingerprint), do: {:error, :invalid_argument, %{argument: :requirements}}

  defp optional_text(nil, _key), do: :ok
  defp optional_text(value, key), do: present(value, key)

  defp optional_route(changes) do
    case Map.get(changes, :route) do
      nil ->
        :ok

      route ->
        reason = text_value(changes, :escalation_reason) || text_value(route, :escalation_reason)
        if validate_route(route, reason) == :ok, do: :ok, else: validate_route(route, reason)
    end
  end

  defp optional_list_of_binaries(nil, _key), do: :ok
  defp optional_list_of_binaries(value, key), do: list_of_binaries(value, key)

  defp optional_fingerprint(nil), do: :ok
  defp optional_fingerprint(value), do: present(value, :requirements_fingerprint)

  defp optional_requirement_revision(nil), do: :ok
  defp optional_requirement_revision(value) when is_integer(value) and value >= 0, do: :ok
  defp optional_requirement_revision(_value), do: {:error, :invalid_argument, %{argument: :requirements_revision}}

  defp requirement_metadata(args) do
    body = Map.get(args, :requirements, Map.get(args, "requirements"))
    fingerprint = text_value(args, :requirements_fingerprint)
    revision = Map.get(args, :requirements_revision, Map.get(args, "requirements_revision"))

    cond do
      is_map(body) and is_nil(fingerprint) ->
        {:error, :requirements_fingerprint_required, %{}}

      not is_nil(revision) and (not is_integer(revision) or revision < 0) ->
        {:error, :invalid_argument, %{argument: :requirements_revision}}

      true ->
        {:ok,
         %{}
         |> maybe_put(:requirements_fingerprint, fingerprint)
         |> maybe_put(:requirements_revision, revision)}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_route(changes) do
    case Map.get(changes, :route, Map.get(changes, "route")) do
      nil ->
        {:ok, nil}

      route ->
        reason = text_value(changes, :escalation_reason) || text_value(route, :escalation_reason)
        if validate_route(route, reason) == :ok, do: {:ok, route}, else: validate_route(route, reason)
    end
  end

  defp dependencies_accepted(assignment, state) when is_map(state) do
    dependencies = assignment.dependencies || []

    if Enum.all?(dependencies, fn id -> get_in(state, [:assignments, id, :phase]) == :accepted end) do
      :ok
    else
      {:error, :dependency_not_accepted, %{dependencies: dependencies}}
    end
  end

  defp dependencies_accepted(_assignment, _state), do: {:error, :dependency_not_accepted, %{}}

  defp duplicate_identity_free?(state, assignment),
    do: duplicate_identity_free_after_revision?(state, nil, assignment)

  defp duplicate_identity_free_after_revision?(state, own_id, assignment) do
    identity = assignment_identity(assignment)

    duplicate =
      Enum.find(state.assignments, fn {id, existing} ->
        id != own_id and assignment_identity(existing) == identity and phase(existing[:phase]) not in @terminal_phases
      end)

    if is_nil(duplicate), do: :ok, else: {:error, :duplicate_underlying_identity, %{assignment_id: elem(duplicate, 0)}}
  end

  defp assignment_identity(assignment) when is_map(assignment) do
    native_issue_id = text_value(assignment, :native_issue_id) || text_value(assignment, :issue_id)

    if native_issue_id do
      "github:issue:" <> native_issue_id
    else
      repository = text_value(assignment, :repository) || ""
      issue_number = number_value(assignment, :issue_number) || 0
      repository <> "#" <> Integer.to_string(issue_number)
    end
  end

  defp assignment_identity(_assignment), do: ""

  defp resources_free?(state, resources, own_id \\ nil) do
    conflicting =
      Enum.find(state.assignments, fn {id, existing} ->
        id != own_id and resource_claiming?(existing) and Enum.any?(resources, &(&1 in (existing.resources || [])))
      end)

    if is_nil(conflicting), do: :ok, else: {:error, :resource_conflict, %{assignment_id: elem(conflicting, 0)}}
  end

  defp resource_claiming?(assignment) do
    assignment.phase in @active_phases or assignment[:stop_pending] == true
  end

  defp stop_reconciled_for_revision(%{phase: phase}, _context) when phase not in [:active, :review], do: :ok

  defp stop_reconciled_for_revision(_assignment, %{stop_reconciled: true}), do: :ok
  defp stop_reconciled_for_revision(_assignment, _context), do: {:error, :active_assignment_stop_required, %{}}

  defp external_effects_reconciled(context) when is_map(context) do
    effects = Map.get(context, :external_effects, %{})
    status = Map.get(effects, :status, Map.get(effects, "status"))
    issue_close = Map.get(effects, :issue_close, Map.get(effects, "issue_close"))

    if Map.get(context, :reconciled) == true and status in [:ok, "ok", :reconciled, "reconciled"] and
         issue_close in [:ok, "ok", :reconciled, "reconciled"] do
      :ok
    else
      {:error, :external_effects_unreconciled, %{}}
    end
  end

  defp fetch_assignment(state, id) do
    case Map.fetch(state.assignments, id) do
      {:ok, assignment} -> {:ok, assignment}
      :error -> {:error, :assignment_not_found, %{assignment_id: id}}
    end
  end

  defp binding_present(%{binding: binding}) when is_map(binding), do: :ok
  defp binding_present(_state), do: {:error, :project_not_bound, %{}}

  defp commit(state, request, canonical, response, patch) do
    event_cursor = Map.get(state, :event_cursor, 0) + 1
    control_revision = Map.get(state, :control_revision, 0) + 1
    next_state = Map.merge(state, patch)

    event = %{
      cursor: event_cursor,
      at: DateTime.utc_now(),
      operation: request.operation,
      request_id: request.request_id,
      assignment_id: Map.get(response, :assignment_id),
      phase: Map.get(response, :phase),
      control_revision: control_revision
    }

    next_state =
      next_state
      |> Map.put(:control_revision, control_revision)
      |> Map.put(:event_cursor, event_cursor)
      |> Map.put(:events, [event | Enum.take(Map.get(state, :events, []), 99)])
      |> put_in([:requests, request.request_id], %{canonical: canonical, response: response})
      |> trim_requests()

    {:ok, next_state, response}
  end

  defp normalize_envelope(envelope) do
    request_id = Map.get(envelope, :request_id, Map.get(envelope, "request_id"))
    operation = Map.get(envelope, :operation, Map.get(envelope, "operation"))
    args = Map.get(envelope, :args, Map.get(envelope, "args"))

    if MapSet.subset?(MapSet.new(Map.keys(envelope)), MapSet.new([:request_id, :operation, :args, "request_id", "operation", "args"])) do
      {:ok, %{request_id: request_id, operation: operation, args: args}}
    else
      {:error, :invalid_envelope, %{}}
    end
  end

  defp normalize_operation(operation) when is_atom(operation) and operation in @operations, do: {:ok, operation}

  defp normalize_operation(operation) when is_binary(operation) do
    operation = String.trim(operation)
    if operation in Enum.map(@operations, &Atom.to_string/1), do: {:ok, String.to_atom(operation)}, else: {:error, :unsupported_operation, %{operation: operation}}
  end

  defp normalize_operation(operation), do: {:error, :unsupported_operation, %{operation: operation}}

  defp normalize_args(args) when is_map(args), do: {:ok, normalize_map(args)}

  defp normalize_args(_args), do: {:error, :args_must_be_map, %{}}

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("expected_revision"), do: :expected_revision
  defp normalize_key("request_id"), do: :request_id
  defp normalize_key("assignment_id"), do: :assignment_id
  defp normalize_key("project_id"), do: :project_id
  defp normalize_key("project_item_id"), do: :project_item_id
  defp normalize_key("native_project_item_id"), do: :native_project_item_id
  defp normalize_key("native_issue_id"), do: :native_issue_id
  defp normalize_key("issue_id"), do: :issue_id
  defp normalize_key("issue_node_id"), do: :issue_node_id
  defp normalize_key("native_repository_id"), do: :native_repository_id
  defp normalize_key("repository_id"), do: :repository_id
  defp normalize_key("repository_node_id"), do: :repository_node_id
  defp normalize_key("status_field_id"), do: :status_field_id
  defp normalize_key("project_number"), do: :project_number
  defp normalize_key("status_options"), do: :status_options
  defp normalize_key("repositories"), do: :repositories
  defp normalize_key("repository"), do: :repository
  defp normalize_key("issue_number"), do: :issue_number
  defp normalize_key("base_commit"), do: :base_commit
  defp normalize_key("board_state"), do: :board_state
  defp normalize_key("phase"), do: :phase
  defp normalize_key("route"), do: :route
  defp normalize_key("resources"), do: :resources
  defp normalize_key("dependencies"), do: :dependencies
  defp normalize_key("changes"), do: :changes
  defp normalize_key("disposition"), do: :disposition
  defp normalize_key("provider_state"), do: :provider_state
  defp normalize_key("evidence"), do: :evidence
  defp normalize_key("reason"), do: :reason
  defp normalize_key("disable"), do: :disable
  defp normalize_key("owner"), do: :owner
  defp normalize_key("project"), do: :project
  defp normalize_key("allowlisted_repositories"), do: :allowlisted_repositories
  defp normalize_key("model"), do: :model
  defp normalize_key("effort"), do: :effort
  defp normalize_key("requirements"), do: :requirements
  defp normalize_key("requirements_fingerprint"), do: :requirements_fingerprint
  defp normalize_key("requirements_revision"), do: :requirements_revision
  defp normalize_key("escalation_reason"), do: :escalation_reason
  defp normalize_key("turn_limit"), do: :turn_limit
  defp normalize_key("issue_body"), do: :issue_body
  defp normalize_key(key), do: key

  defp normalize_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc -> Map.put(acc, normalize_key(key), normalize_map(value)) end)
  end

  defp normalize_map(list) when is_list(list), do: Enum.map(list, &normalize_map/1)
  defp normalize_map(value), do: value

  defp validate_request_id(id), do: present(id, :request_id)

  defp text_value(map, key) when is_map(map) do
    map |> Map.get(key, Map.get(map, Atom.to_string(key))) |> normalize_text()
  end

  defp text_value(_map, _key), do: nil

  defp number_value(map, key) when is_map(map) do
    value = Map.get(map, key, Map.get(map, Atom.to_string(key)))
    if is_integer(value) and value > 0, do: value, else: value
  end

  defp number_value(_map, _key), do: nil

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(_value), do: nil

  defp present(value, _key) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp present(_value, key), do: {:error, :invalid_argument, %{argument: key}}

  defp positive(value, _key) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, key), do: {:error, :invalid_argument, %{argument: key}}

  defp list_of_binaries(value, key) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: :ok, else: {:error, :invalid_argument, %{argument: key}}
  end

  defp list_of_binaries(_value, key), do: {:error, :invalid_argument, %{argument: key}}

  defp phase_is(actual, expected) when actual == expected, do: :ok
  defp phase_is(actual, expected), do: {:error, :invalid_phase, %{expected: expected, actual: actual}}

  defp provider_phase_is(:review, _expected), do: :ok
  defp provider_phase_is(actual, _expected), do: {:error, :provider_state_not_review, %{provider_state: actual}}

  defp evidence_present(value) when is_list(value) and value != [], do: :ok
  defp evidence_present(_value), do: {:error, :evidence_required, %{}}

  defp normalize_evidence(evidence), do: Enum.take(evidence, 20)

  defp transition_targets(nil), do: [:bound, :ready]
  defp transition_targets(:idle), do: [:bound]
  defp transition_targets(:bound), do: [:ready, :cancelled]
  defp transition_targets(:ready), do: [:active, :cancelled, :waiting]
  defp transition_targets(:active), do: [:review, :waiting, :cancelled]
  defp transition_targets(:waiting), do: [:ready, :active, :cancelled, :review]
  defp transition_targets(:review), do: [:accepted, :ready, :waiting, :cancelled]
  defp transition_targets(:accepted), do: []
  defp transition_targets(:cancelled), do: []
  defp transition_targets(_), do: []

  defp drop_issue_content(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, _value} -> normalize_key(key) in [:requirements, :issue_body] end)
    |> Enum.map(fn {key, value} -> {key, drop_issue_content(value)} end)
    |> Map.new()
  end

  defp drop_issue_content(list) when is_list(list), do: Enum.map(list, &drop_issue_content/1)
  defp drop_issue_content(value), do: value

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {canonical_term(key), canonical_term(value)} end)
    |> Enum.sort()
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)
  defp canonical_term(value), do: value

  defp assignment_snapshots(assignments) do
    Enum.map(assignments, fn {id, assignment} -> {id, assignment} end) |> Map.new()
  end

  defp trim_requests(%{requests: requests} = state) when map_size(requests) <= 100, do: state

  defp trim_requests(%{requests: requests} = state) do
    %{state | requests: requests |> Enum.take(100) |> Map.new()}
  end
end
