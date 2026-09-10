defmodule SymphonyElixir.Managed.Rules do
  @moduledoc """
  Deterministic lifecycle and control rules for the managed scheduler.

  This module has no process or provider side effects. The Orchestrator applies
  the returned state and persists it through the managed journal.
  """

  alias SymphonyElixir.Managed.{Ownership, Resources}

  @version 2
  @operations ~w(bind_project register_pm enroll claim handoff operator_takeover revise pause resume interrupt cancel review)a
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
      projects: Keyword.get(opts, :projects, %{}),
      principals: Keyword.get(opts, :principals, %{}),
      assignments: Keyword.get(opts, :assignments, %{}),
      requests: Keyword.get(opts, :requests, %{}),
      handoff_intents: Keyword.get(opts, :handoff_intents, %{}),
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

  @spec authorize(state(), envelope(), map()) :: :ok | {:error, atom(), map()}
  def authorize(state, envelope, principal_context) when is_map(state) and is_map(envelope) and is_map(principal_context) do
    with {:ok, normalized} <- normalize_envelope(envelope),
         :ok <- validate_request_id(normalized.request_id),
         {:ok, operation} <- normalize_operation(normalized.operation),
         {:ok, args} <- normalize_args(normalized.args),
         {:ok, principal} <- principal_context(principal_context),
         :ok <- authorize_operation(state, operation, args, principal) do
      _ = normalized
      _ = args
      _ = operation
      _ = principal
      :ok
    else
      {:error, code, details} -> {:error, code, details}
    end
  end

  def authorize(_state, _envelope, _principal_context), do: {:error, :principal_required, %{}}

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
         {:ok, args} <- normalize_args(normalized.args),
         {:ok, principal} <- principal_context(context),
         :ok <- authorize_operation(state, operation, args, principal) do
      normalized = normalized |> Map.merge(%{operation: operation, args: args}) |> Map.put(:principal, principal)
      canonical = canonical_input(normalized)
      apply_or_replay(state, normalized, canonical, principal, context)
    else
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp apply_or_replay(state, normalized, canonical, principal, context) do
    case Map.get(state.requests, normalized.request_id) do
      %{canonical: ^canonical} = record ->
        duplicate_or_principal_conflict(record, principal, normalized.request_id)

      %{canonical: _other} ->
        {:error, :request_id_conflict, %{request_id: normalized.request_id}}

      nil ->
        apply_new(state, normalized, canonical, context)
    end
  end

  defp duplicate_or_principal_conflict(record, principal, request_id) do
    if request_principal_allowed?(record, principal) do
      {:duplicate, record.response}
    else
      {:error, :request_principal_conflict, %{request_id: request_id}}
    end
  end

  @doc false
  @spec prepare_review(state(), envelope()) ::
          {:ok, map()} | {:duplicate, map()} | {:error, atom(), map()}
  def prepare_review(state, envelope) when is_map(state) and is_map(envelope) do
    prepare_review(state, envelope, %{})
  end

  @spec prepare_review(state(), envelope(), map()) ::
          {:ok, map()} | {:duplicate, map()} | {:error, atom(), map()}
  def prepare_review(state, envelope, context) when is_map(state) and is_map(envelope) and is_map(context) do
    with {:ok, normalized} <- normalize_envelope(envelope),
         :ok <- validate_request_id(normalized.request_id),
         {:ok, args} <- normalize_args(normalized.args),
         {:ok, principal} <- principal_context(context),
         {:ok, :review} <- normalize_operation(normalized.operation) do
      normalized = normalized |> Map.merge(%{operation: :review, args: args}) |> Map.put(:principal, principal)
      canonical = canonical_input(normalized)

      prepare_review_result(state, normalized, canonical, principal, args)
    else
      {:ok, operation} -> {:error, :unsupported_operation, %{operation: operation}}
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp prepare_review_result(state, normalized, canonical, principal, args) do
    case Map.get(state.requests, normalized.request_id) do
      %{canonical: ^canonical} = record ->
        duplicate_or_principal_conflict(record, principal, normalized.request_id)

      %{canonical: _other} ->
        {:error, :request_id_conflict, %{request_id: normalized.request_id}}

      nil ->
        review_intent(state, normalized, canonical, args)
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
         request: Map.delete(normalized, :principal),
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

  defp principal_context(context) when is_map(context) and map_size(context) == 0, do: {:error, :principal_required, %{}}

  defp principal_context(context) when is_map(context) do
    cond do
      Map.has_key?(context, :principal_context) or Map.has_key?(context, "principal_context") ->
        Ownership.principal(Map.get(context, :principal_context, Map.get(context, "principal_context")))

      principal_context_key?(context) ->
        Ownership.principal(context)

      true ->
        {:error, :principal_required, %{}}
    end
  end

  defp principal_context(_context), do: {:error, :principal_required, %{}}

  defp principal_context_key?(context) do
    Enum.any?([:principal, "principal", :principal_id, "principal_id"], &Map.has_key?(context, &1))
  end

  defp authorize_operation(_state, :bind_project, _args, %{role: :operator}), do: :ok

  defp authorize_operation(_state, :bind_project, _args, _principal),
    do: {:error, :operator_required, %{operation: :bind_project}}

  defp authorize_operation(_state, :operator_takeover, _args, %{role: :operator}), do: :ok

  defp authorize_operation(_state, :operator_takeover, _args, _principal),
    do: {:error, :operator_required, %{operation: :operator_takeover}}

  defp authorize_operation(_state, :register_pm, _args, _principal), do: :ok
  defp authorize_operation(state, :enroll, args, principal), do: authorize_enrollment(state, args, principal)
  defp authorize_operation(state, :claim, args, principal), do: authorize_claim(state, args, principal)
  defp authorize_operation(state, :handoff, args, principal), do: authorize_handoff(state, args, principal)

  defp authorize_operation(state, operation, args, principal)
       when operation in [:pause, :resume] do
    authorize_pause_resume(state, args, principal)
  end

  defp authorize_operation(state, operation, args, principal)
       when operation in [:revise, :interrupt, :cancel, :review] do
    authorize_assignment_operation(state, args, principal)
  end

  defp authorize_enrollment(state, args, principal) do
    project_id = text_value(args, :project_id)

    with :ok <- require_pm(principal),
         :ok <- require_project_id(project_id),
         :ok <- Ownership.authorize_project(principal, project_id),
         {:ok, _binding} <- fetch_project_binding(state, project_id) do
      :ok
    end
  end

  defp authorize_claim(state, args, principal) do
    assignment_id = text_value(args, :assignment_id)
    project_id = text_value(args, :project_id)

    with :ok <- require_pm(principal),
         :ok <- require_project_id(project_id),
         :ok <- Ownership.authorize_project(principal, project_id),
         {:ok, assignment} <- fetch_assignment(state, assignment_id),
         :ok <- Ownership.authorize_project(principal, text_value(assignment, :project_id) || project_id),
         :ok <- assignment_project_matches(assignment, project_id) do
      claimable_assignment(assignment, assignment_id)
    end
  end

  defp claimable_assignment(assignment, assignment_id) do
    if Ownership.ownership(assignment).status == :unassigned do
      :ok
    else
      {:error, :operator_takeover_required, %{assignment_id: assignment_id}}
    end
  end

  defp authorize_handoff(state, args, principal) do
    project_id = text_value(args, :project_id)

    with :ok <- require_project_id(project_id),
         :ok <- Ownership.authorize_project(principal, project_id),
         {:ok, assignment_ids} <- assignment_fence_ids(args) do
      authorize_assignment_scope(state, assignment_ids, project_id, principal)
    end
  end

  defp authorize_pause_resume(state, args, principal) do
    scope = text_value(args, :scope) || if(Map.has_key?(args, :assignments), do: "assignments", else: "service")

    case String.downcase(scope) do
      "service" when principal.role == :operator ->
        :ok

      "service" ->
        {:error, :operator_required, %{scope: :service}}

      "assignments" ->
        project_id = text_value(args, :project_id)

        with :ok <- require_project_id(project_id),
             :ok <- Ownership.authorize_project(principal, project_id),
             {:ok, assignment_ids} <- assignment_fence_ids(args) do
          authorize_assignment_scope(state, assignment_ids, project_id, principal)
        end

      _ ->
        {:error, :invalid_scope, %{scope: scope}}
    end
  end

  defp authorize_assignment_operation(state, args, principal) do
    assignment_id = text_value(args, :assignment_id)
    project_id = text_value(args, :project_id)

    with {:ok, assignment} <- fetch_assignment(state, assignment_id),
         :ok <- require_project_id(project_id),
         :ok <-
           Ownership.authorize_assignment(
             principal,
             assignment,
             project_id || text_value(assignment, :project_id)
           ) do
      Ownership.expected_ownership_revision(assignment, args)
    end
  end

  defp authorize_assignment_scope(state, ids, project_id, principal) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      authorize_assignment_scope_entry(state, id, project_id, principal)
    end)
  end

  defp authorize_assignment_scope_entry(state, id, project_id, principal) do
    with {:ok, assignment} <- fetch_assignment(state, id),
         :ok <- Ownership.authorize_assignment(principal, assignment, project_id) do
      {:cont, :ok}
    else
      error -> {:halt, error}
    end
  end

  defp require_pm(%{role: :pm}), do: :ok
  defp require_pm(_principal), do: {:error, :pm_required, %{}}

  defp require_project_id(nil), do: {:error, :project_required, %{}}
  defp require_project_id(""), do: {:error, :project_required, %{}}
  defp require_project_id(_project_id), do: :ok

  defp assignment_fence_ids(args) when is_map(args) do
    assignments = Map.get(args, :assignments, Map.get(args, "assignments"))

    if is_list(assignments) and assignments != [] do
      reduce_assignment_fences(assignments)
    else
      {:error, :invalid_argument, %{argument: :assignments}}
    end
  end

  defp reduce_assignment_fences(assignments) do
    Enum.reduce_while(assignments, {:ok, []}, fn fence, {:ok, ids} ->
      append_assignment_fence(fence, ids)
    end)
  end

  defp append_assignment_fence(fence, _ids) when not is_map(fence) do
    {:halt, {:error, :invalid_argument, %{argument: :assignments}}}
  end

  defp append_assignment_fence(fence, ids) do
    id = text_value(fence, :assignment_id)

    cond do
      is_nil(id) ->
        {:halt, {:error, :invalid_argument, %{argument: :assignments}}}

      id in ids ->
        {:halt, {:error, :duplicate_assignment, %{assignment_id: id}}}

      true ->
        {:cont, {:ok, ids ++ [id]}}
    end
  end

  defp apply_new(state, %{operation: :bind_project, args: args} = request, canonical, _context),
    do: apply_binding(state, request, canonical, args)

  defp apply_new(state, %{operation: :register_pm, args: args} = request, canonical, context),
    do: apply_register_pm(state, request, canonical, args, context)

  defp apply_new(state, %{operation: :enroll, args: args} = request, canonical, context),
    do: apply_enrollment(state, request, canonical, args, context)

  defp apply_new(state, %{operation: :claim, args: args} = request, canonical, context),
    do: apply_claim(state, request, canonical, args, context)

  defp apply_new(state, %{operation: operation, args: args} = request, canonical, context)
       when operation in [:handoff, :operator_takeover] do
    apply_handoff(state, request, canonical, args, context, operation)
  end

  defp apply_new(state, %{operation: :revise, args: args} = request, canonical, context),
    do: apply_revision(state, request, canonical, args, context)

  defp apply_new(state, %{operation: operation, args: args} = request, canonical, _context)
       when operation in [:pause, :resume] do
    apply_pause_resume(state, request, canonical, args, operation)
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

  defp apply_register_pm(state, request, canonical, args, _context) do
    principal = request.principal
    display_name = text_value(args, :display_name)

    with :ok <- require_pm(principal) do
      metadata = %{principal_id: principal.principal_id, role: :pm} |> maybe_put(:display_name, display_name)
      principals = Map.put(Map.get(state, :principals, %{}), principal.principal_id, metadata)
      response = %{operation: :register_pm, principal_id: principal.principal_id, registered: true}
      commit(state, request, canonical, response, %{principals: principals})
    end
  end

  defp apply_claim(state, request, canonical, args, _context) do
    assignment_id = text_value(args, :assignment_id)
    principal = request.principal

    with :ok <- present(assignment_id, :assignment_id),
         {:ok, assignment} <- fetch_assignment(state, assignment_id),
         :ok <- expected_revision(state, args, {:assignment, assignment_id}),
         :ok <- Ownership.expected_ownership_revision(assignment, args),
         {:ok, claimed} <- Ownership.claim(assignment, principal) do
      assignments = Map.put(state.assignments, assignment_id, claimed)
      principals = maybe_register_principal(state, principal)
      response = %{operation: :claim, assignment_id: assignment_id, revision: claimed.revision, ownership_revision: claimed.ownership.ownership_revision, phase: claimed.phase}
      commit(state, request, canonical, response, %{assignments: assignments, principals: principals})
    end
  end

  defp apply_handoff(state, request, canonical, args, context, operation) do
    project_id = text_value(args, :project_id)
    target = target_principal(state, args, context)
    source = request.principal

    with {:ok, assignment_ids} <- assignment_fence_ids(args),
         {:ok, target} <- target,
         :ok <- target_is_distinct(source, target),
         :ok <- exact_resource_scope(state, assignment_ids),
         {:ok, updated} <- transfer_assignments(state, assignment_ids, project_id, args, target, operation),
         :ok <- no_uncertain_effects(state, assignment_ids, context) do
      updated = clear_verified_stop_pending(updated, context)
      handoff_id = text_value(args, :handoff_id) || request.request_id

      intent = %{
        request_id: request.request_id,
        handoff_id: handoff_id,
        assignment_ids: assignment_ids,
        project_id: project_id,
        source_principal_id: source.principal_id,
        target_principal_id: target.principal_id,
        reason: text_value(args, :reason),
        status: :complete
      }

      handoffs = Map.put(Map.get(state, :handoff_intents, %{}), request.request_id, intent)
      effect_intents = invalidate_owner_intents(Map.get(state, :effect_intents, %{}), assignment_ids, source.principal_id)
      review_intents = invalidate_owner_intents(Map.get(state, :review_intents, %{}), assignment_ids, source.principal_id)

      response = %{
        operation: operation,
        handoff_id: handoff_id,
        assignment_ids: assignment_ids,
        source_pm_id: source.principal_id,
        destination_pm_id: target.principal_id,
        target_principal_id: target.principal_id,
        reason: text_value(args, :reason),
        status: :complete
      }

      commit(
        state,
        request,
        canonical,
        response,
        %{
          assignments: updated,
          handoff_intents: handoffs,
          effect_intents: effect_intents,
          review_intents: review_intents
        }
      )
    end
  end

  defp transfer_assignments(state, ids, project_id, args, target, operation) do
    Enum.reduce_while(ids, {:ok, state.assignments}, fn id, {:ok, assignments} ->
      case transfer_assignment(state, assignments, id, project_id, args, target, operation) do
        {:ok, changed} -> {:cont, {:ok, Map.put(assignments, id, changed)}}
        {:error, code, details} -> {:halt, {:error, code, details}}
      end
    end)
  end

  defp transfer_assignment(state, assignments, id, project_id, args, target, operation) do
    with {:ok, assignment} <- Map.fetch(assignments, id),
         :ok <- assignment_project_matches(assignment, project_id),
         :ok <- duplicate_identity_free_after_revision?(state, id, assignment),
         :ok <- expected_revision_for(state, args, id, assignment),
         :ok <- expected_ownership_revision_for(args, id, assignment),
         {:ok, changed} <- transfer_one(assignment, target, operation, args) do
      {:ok, changed}
    else
      {:error, code, details} -> {:error, code, Map.put(details, :assignment_id, id)}
    end
  end

  defp transfer_one(assignment, target, :handoff, args) do
    case Ownership.transfer(assignment, target, text_value(args, :handoff_id)) do
      {:ok, changed} -> {:ok, changed}
      error -> error
    end
  end

  defp transfer_one(assignment, target, :operator_takeover, args) do
    case Ownership.takeover(assignment, target, text_value(args, :handoff_id)) do
      {:ok, changed} -> {:ok, changed}
      error -> error
    end
  end

  defp target_principal(state, args, _context) do
    target_id = text_value(args, :destination_pm_id)

    with :ok <- present(target_id, :destination_pm_id),
         true <- registered_pm?(state, target_id),
         {:ok, target} <- Ownership.principal(%{principal_id: target_id, role: :pm, project_scope: :all}) do
      {:ok, target}
    else
      false -> {:error, :target_principal_not_registered, %{principal_id: target_id}}
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp registered_pm?(state, principal_id) do
    metadata = Map.get(Map.get(state, :principals, %{}), principal_id)
    is_map(metadata) and Map.get(metadata, :role, Map.get(metadata, "role")) in [:pm, "pm"]
  end

  defp target_is_distinct(%{principal_id: source}, %{principal_id: source}), do: {:error, :target_principal_same_as_source, %{}}
  defp target_is_distinct(_source, _target), do: :ok

  defp exact_resource_scope(state, ids) do
    if Enum.all?(ids, &is_map(Map.get(state.assignments, &1))) do
      :ok
    else
      {:error, :assignment_not_found, %{}}
    end
  end

  defp no_uncertain_effects(state, ids, context) do
    pending = Map.get(state, :effect_intents, %{})
    stopped_ids = MapSet.new(Map.get(context, :stopped_assignment_ids, []))

    cond do
      Map.get(context, :effects_reconciled) == true ->
        :ok

      Enum.any?(ids, fn id ->
        get_in(state, [:assignments, id, :stop_pending]) == true and
            not MapSet.member?(stopped_ids, id)
      end) ->
        {:error, :handoff_effect_pending, %{}}

      Enum.any?(ids, fn id -> pending_intent?(pending, id) end) ->
        {:error, :handoff_effect_pending, %{}}

      true ->
        :ok
    end
  end

  defp clear_verified_stop_pending(assignments, context) when is_map(assignments) and is_map(context) do
    stopped_ids = MapSet.new(Map.get(context, :stopped_assignment_ids, []))

    Map.new(assignments, fn {id, assignment} ->
      if MapSet.member?(stopped_ids, id) and is_map(assignment) do
        {id, Map.merge(assignment, %{stop_pending: false, stop_reconciled: true})}
      else
        {id, assignment}
      end
    end)
  end

  defp pending_intent?(intents, id) when is_map(intents) do
    Enum.any?(intents, fn {_request_id, intent} -> is_map(intent) and text_value(intent, :assignment_id) == id and Map.get(intent, :status, Map.get(intent, "status")) in [:pending, "pending"] end)
  end

  defp pending_intent?(_intents, _id), do: false

  defp invalidate_owner_intents(intents, assignment_ids, source_principal_id) when is_map(intents) do
    Map.new(intents, fn {request_id, intent} ->
      stale? =
        is_map(intent) and
          text_value(intent, :assignment_id) in assignment_ids and
          owner_intent?(intent, source_principal_id) and
          Map.get(intent, :status, Map.get(intent, "status")) in [:pending, "pending"]

      value =
        if stale? do
          intent |> Map.put(:status, :stale_owner) |> Map.put(:stale_owner_id, source_principal_id)
        else
          intent
        end

      {request_id, value}
    end)
  end

  defp invalidate_owner_intents(intents, _assignment_ids, _source_principal_id), do: intents

  defp owner_intent?(intent, source_principal_id) do
    principal = Map.get(intent, :principal_context, Map.get(intent, "principal_context", %{}))

    text_value(principal, :principal_id) == source_principal_id or
      is_integer(Map.get(intent, :ownership_revision, Map.get(intent, "ownership_revision")))
  end

  defp apply_pause_resume(state, request, canonical, args, operation) do
    scope =
      text_value(args, :scope) ||
        if(Map.has_key?(args, :assignments), do: "assignments", else: "service")

    case String.downcase(scope) do
      "service" -> apply_service_pause(state, request, canonical, args, operation)
      "assignments" -> apply_assignment_pause(state, request, canonical, args, operation)
    end
  end

  defp apply_service_pause(state, request, canonical, args, operation) do
    with :ok <- expected_revision(state, args, :global) do
      paused = operation == :pause
      disabled = paused and Map.get(args, :disable, false) == true

      response = %{
        operation: operation,
        revision: state.control_revision + 1,
        paused: paused,
        disabled: disabled,
        scope: :service
      }

      commit(state, request, canonical, response, %{paused: paused, disabled: disabled})
    end
  end

  defp apply_assignment_pause(state, request, canonical, args, operation) do
    project_id = text_value(args, :project_id)

    with {:ok, ids} <- assignment_fence_ids(args),
         {:ok, assignments} <- pause_assignments(state, ids, project_id, args, operation) do
      response = %{
        operation: operation,
        scope: :assignments,
        project_id: project_id,
        assignment_ids: ids,
        revision: state.control_revision + 1
      }

      commit(state, request, canonical, response, %{assignments: assignments})
    end
  end

  defp pause_assignments(state, ids, project_id, args, operation) do
    Enum.reduce_while(ids, {:ok, state.assignments}, fn id, {:ok, assignments} ->
      case pause_assignment(state, assignments, id, project_id, args, operation) do
        {:ok, changed} -> {:cont, {:ok, Map.put(assignments, id, changed)}}
        {:error, code, details} -> {:halt, {:error, code, details}}
      end
    end)
  end

  defp pause_assignment(state, assignments, id, project_id, args, operation) do
    with {:ok, assignment} <- Map.fetch(assignments, id),
         :ok <- assignment_project_matches(assignment, project_id),
         :ok <- expected_revision_for(state, args, id, assignment),
         :ok <- expected_ownership_revision_for(args, id, assignment),
         :ok <- valid_pause_operation(operation) do
      {:ok, Map.put(assignment, :dispatch_paused, operation == :pause)}
    else
      {:error, code, details} -> {:error, code, Map.put(details, :assignment_id, id)}
    end
  end

  defp valid_pause_operation(operation) when operation in [:pause, :resume], do: :ok

  defp apply_binding(state, request, canonical, args) do
    with :ok <- expected_revision(state, args, :global),
         {:ok, binding} <- binding_from_args(args),
         :ok <- binding_rebind_allowed?(state, binding) do
      project = Map.merge(binding, %{revision: project_revision(state, binding.project_id) + 1, dispatch_paused: false})
      response = %{operation: :bind_project, project: project, revision: state.control_revision + 1}
      commit(state, request, canonical, response, %{projects: Map.put(Map.get(state, :projects, %{}), binding.project_id, project)})
    end
  end

  # A project binding is an authority boundary. Replacing it while any
  # assignment is still owned by the service could make the old worker mutate
  # a different project after restart.
  defp binding_rebind_allowed?(state, binding) do
    current = Map.get(state, :projects, %{}) |> Map.get(binding.project_id)

    cond do
      is_map(current) and Map.take(current, Map.keys(binding)) == binding -> :ok
      is_nil(current) -> :ok
      true -> binding_rebind_conflict_for_project(state, binding.project_id)
    end
  end

  defp binding_rebind_conflict_for_project(state, project_id) do
    case Enum.find(state.assignments, fn {_id, assignment} ->
           is_map(assignment) and
             text_value(assignment, :project_id) == project_id and
             phase(assignment[:phase]) not in @terminal_phases
         end) do
      nil ->
        :ok

      {assignment_id, assignment} ->
        {:error, :binding_in_use, %{assignment_id: assignment_id, phase: phase(assignment[:phase])}}
    end
  end

  defp apply_enrollment(state, request, canonical, args, context) do
    principal = Map.get(request, :principal)
    project_id = text_value(args, :project_id)

    with :ok <- expected_revision(state, args, :global),
         {:ok, binding} <- fetch_project_binding(state, project_id),
         {:ok, assignment} <- assignment_from_args(args, []),
         assignment <- merge_source_identity(assignment, context),
         :ok <- repository_in_binding(binding, assignment.repository),
         :ok <- duplicate_identity_free?(state, assignment),
         :ok <- resources_free?(state, assignment.resources) do
      assignment =
        assignment
        |> Map.put(:project_id, project_id)
        |> Map.put(:revision, 1)
        |> maybe_assign_owner(principal)

      assignments = Map.put(state.assignments, assignment.assignment_id, assignment)
      principals = maybe_register_principal(state, principal)

      response = %{
        operation: :enroll,
        assignment_id: assignment.assignment_id,
        revision: 1,
        phase: assignment.phase,
        project_id: project_id,
        control_revision: state.control_revision + 1
      }

      commit(state, request, canonical, response, %{assignments: assignments, principals: principals})
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

  defp assignment_operation(:interrupt, assignment, args, _state, context) do
    reason = text_value(args, :reason)

    with :ok <- present(reason, :reason),
         :ok <- phase_is(assignment.phase, :active) do
      updates = %{blocked_reason: reason, board_state: :waiting, stop_pending: transition_stop_pending?(context)}
      response = %{operation: :interrupt, reason: reason}
      {:ok, :waiting, updates, response}
    end
  end

  defp assignment_operation(:cancel, assignment, args, _state, context) do
    reason = text_value(args, :reason) || "cancelled by operator"

    if assignment.phase in @terminal_phases do
      {:error, :already_terminal, %{phase: assignment.phase}}
    else
      updates = %{disposition_reason: reason, board_state: :cancelled, stop_pending: transition_stop_pending?(context)}
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

      true ->
        {:error, :invalid_disposition, %{disposition: disposition}}
    end
  end

  defp transition_stop_pending?(context), do: Map.get(context, :stop_reconciled) != true

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
    evidence = Map.get(args, :evidence, [])

    with :ok <- present(reason, :reason),
         :ok <- review_feedback_evidence(evidence) do
      next_phase = if disposition == :waiting, do: :waiting, else: :ready

      updates = %{
        board_state: next_phase,
        review_feedback: %{reason: reason, evidence: evidence}
      }

      response = %{operation: :review, disposition: disposition, reason: reason}
      {:ok, next_phase, updates, response}
    end
  end

  defp binding_from_args(args) do
    project = Map.get(args, :project, args)
    project_id = text_value(project, :project_id)
    status_field_id = text_value(project, :status_field_id)
    projection_field_value = Map.get(project, :projection_field_id, Map.get(project, "projection_field_id"))
    projection_field_id = text_value(project, :projection_field_id)
    project_number = number_value(project, :project_number)

    with :ok <- present(project_id, :project_id),
         :ok <- present(status_field_id, :status_field_id),
         :ok <- positive(project_number, :project_number),
         :ok <- optional_text_value(projection_field_value, :projection_field_id),
         {:ok, options} <- status_options(project),
         {:ok, repositories} <- repository_allowlist(project) do
      {:ok,
       %{
         project_id: project_id,
         project_number: project_number,
         status_field_id: status_field_id,
         status_options: options,
         repositories: repositories
       }
       |> maybe_put(:projection_field_id, projection_field_id)}
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

  defp assignment_from_args(args, opts) do
    input = assignment_input(args)

    with :ok <- reject_obsolete_enrollment_inputs(args),
         :ok <- present(input.assignment_id, :assignment_id),
         :ok <- present(input.repository, :repository),
         :ok <- positive(input.issue_number, :issue_number),
         :ok <- present(input.base_commit, :base_commit),
         :ok <- phase_is(input.board_state, :ready),
         :ok <- validate_route(input.route, input.escalation_reason),
         {:ok, resources} <- assignment_resources(input.resources, opts),
         :ok <- list_of_binaries(input.dependencies, :dependencies),
         {:ok, requirements} <- requirement_metadata(args) do
      {:ok, assignment_payload(input, resources, requirements)}
    end
  end

  defp reject_obsolete_enrollment_inputs(args) do
    case Enum.find([:owner, :native_project_item_id, :issue_id, :issue_node_id, :repository_id, :repository_node_id], fn key ->
           Map.has_key?(args, key) or Map.has_key?(args, Atom.to_string(key))
         end) do
      nil -> :ok
      key -> {:error, :invalid_argument, %{argument: key}}
    end
  end

  defp assignment_input(args) do
    assignment_id = text_value(args, :assignment_id)
    project_item_id = text_value(args, :project_item_id)

    %{
      assignment_id: assignment_id,
      provider: value_or_default(text_value(args, :provider), "github"),
      repository: text_value(args, :repository),
      issue_number: number_value(args, :issue_number),
      base_commit: text_value(args, :base_commit),
      board_state: phase(assignment_board_state(args)),
      route: Map.get(args, :route, Map.get(args, "route", %{model: "gpt-5.6-luna", effort: "xhigh"})),
      resources: Map.get(args, :resources, Map.get(args, "resources", [])),
      dependencies: Map.get(args, :dependencies, Map.get(args, "dependencies", [])),
      project_item_id: value_or_default(project_item_id, assignment_id),
      native_issue_id: text_value(args, :native_issue_id),
      native_repository_id: text_value(args, :native_repository_id),
      escalation_reason: text_value(args, :escalation_reason),
      turn_limit: min(value_or_default(number_value(args, :turn_limit), 20), 20)
    }
  end

  defp assignment_board_state(args) do
    Map.get(args, :board_state, "READY")
  end

  defp assignment_payload(input, resources, requirements) do
    %{
      assignment_id: input.assignment_id,
      provider: input.provider,
      repository: input.repository,
      issue_number: input.issue_number,
      base_commit: input.base_commit,
      phase: :ready,
      board_state: :ready,
      resources: Enum.uniq(resources),
      dependencies: Enum.uniq(input.dependencies),
      route: input.route,
      escalation_reason: input.escalation_reason,
      project_item_id: input.project_item_id,
      native_issue_id: input.native_issue_id,
      native_repository_id: input.native_repository_id,
      underlying_issue_id: underlying_issue_id(input),
      turn_limit: input.turn_limit,
      turns_reserved: 0,
      retry_count: 0,
      enrolled_at: DateTime.utc_now()
    }
    |> Map.merge(requirements)
  end

  defp underlying_issue_id(%{native_issue_id: issue_id}) when is_binary(issue_id), do: issue_id

  defp underlying_issue_id(%{repository: repository, issue_number: issue_number}) do
    repository <> "#" <> Integer.to_string(issue_number)
  end

  defp value_or_default(nil, default), do: default
  defp value_or_default(value, _default), do: value

  defp merge_source_identity(assignment, context) when is_map(assignment) and is_map(context) do
    source = Map.get(context, :source_identity, Map.get(context, "source_identity", %{}))

    if is_map(source) do
      assignment
      |> maybe_put_source_identity(:native_issue_id, source)
      |> maybe_put_source_identity(:native_repository_id, source)
      |> maybe_put_source_identity(:requirements_fingerprint, source)
      |> maybe_put_source_identity(:title, source)
      |> maybe_put_source_identity(:issue_url, source)
    else
      assignment
    end
  end

  defp maybe_put_source_identity(assignment, key, source) do
    value = Map.get(source, key, Map.get(source, Atom.to_string(key)))

    if is_binary(value) and String.trim(value) != "" do
      Map.put(assignment, key, String.trim(value))
    else
      assignment
    end
  end

  defp repository_in_binding(%{repositories: allowlist}, repository) when is_list(allowlist) do
    if repository in allowlist, do: :ok, else: {:error, :repository_not_allowlisted, %{repository: repository}}
  end

  defp repository_in_binding(_binding, _repository), do: {:error, :project_not_bound, %{}}

  defp project_revision(state, project_id) do
    get_in(state, [:projects, project_id, :revision]) || 0
  end

  defp fetch_project_binding(state, project_id) do
    projects = Map.get(state, :projects, %{})

    case Map.get(projects, project_id) do
      binding when is_map(binding) ->
        {:ok, binding}

      _ ->
        {:error, :project_not_bound, %{}}
    end
  end

  defp assignment_project_matches(assignment, project_id) do
    actual = text_value(assignment, :project_id)

    if actual == project_id do
      :ok
    else
      {:error, :assignment_project_mismatch, %{project_id: project_id, assignment_project_id: actual}}
    end
  end

  defp maybe_assign_owner(assignment, %{role: :pm} = principal), do: Map.put(assignment, :ownership, Ownership.assigned(principal))

  defp maybe_register_principal(state, %{role: :pm} = principal) do
    metadata = %{principal_id: principal.principal_id, role: :pm}
    Map.put_new(Map.get(state, :principals, %{}), principal.principal_id, metadata)
  end

  defp assignment_resources(resources, _opts) do
    case Resources.normalize_all(resources) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _code, _details} -> {:error, :invalid_argument, %{argument: :resources}}
    end
  end

  defp expected_revision_for(state, args, id, assignment) do
    expected = expected_value(args, :expected_revisions, id)

    actual = get_in(state, [:assignments, id, :revision]) || Map.get(assignment, :revision)

    cond do
      not is_integer(expected) -> {:error, :expected_revision_required, %{assignment_id: id}}
      expected != actual -> {:error, :stale_revision, %{assignment_id: id, expected: expected, actual: actual}}
      true -> :ok
    end
  end

  defp expected_ownership_revision_for(args, id, assignment) do
    expected = expected_value(args, :expected_ownership_revisions, id)

    actual = Ownership.ownership(assignment).ownership_revision

    cond do
      not is_integer(expected) ->
        {:error, :expected_ownership_revision_required, %{assignment_id: id}}

      expected != actual ->
        {:error, :stale_ownership_revision, %{assignment_id: id, expected: expected, actual: actual}}

      true ->
        :ok
    end
  end

  defp expected_value(args, key, id) do
    expectations = Map.get(args, :assignments, Map.get(args, "assignments", []))

    expectation =
      Enum.find(expectations, fn item ->
        is_map(item) and text_value(item, :assignment_id) == to_string(id)
      end)

    case key do
      :expected_revisions -> expectation && Map.get(expectation, :expected_revision, Map.get(expectation, "expected_revision"))
      :expected_ownership_revisions -> expectation && Map.get(expectation, :expected_ownership_revision, Map.get(expectation, "expected_ownership_revision"))
    end
  end

  defp revise_assignment(assignment, changes, route) do
    revised =
      assignment
      |> Map.merge(Map.drop(changes, [:assignment_id, :expected_revision]))
      |> Map.put(:revision, assignment.revision + 1)
      |> Map.put(:phase, :ready)
      |> Map.put(:board_state, :ready)
      # A successful operator revision starts a fresh automatic retry window.
      # Lifetime turn accounting and the existing workspace/session are retained.
      |> Map.put(:retry_count, 0)
      |> Map.drop([:blocked_reason, :review_feedback])
      |> Map.put(:route, route || assignment.route)
      |> reset_changed_route_session(assignment.route)

    {:ok, revised}
  end

  defp reset_changed_route_session(revised, previous_route) do
    if Enum.any?([:model, :effort], &(text_value(revised.route, &1) != text_value(previous_route, &1))) do
      revised
      |> Map.drop([
        :thread_id,
        :session_id,
        :turn_id,
        :thread_model,
        :turn_model,
        :turn_effort,
        :thread_default_reasoning_effort,
        :metadata
      ])
      |> Map.put(:resume_ready, false)
    else
      revised
    end
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
         {:ok, normalized_resources} <- optional_resources(resources),
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
        |> maybe_put(:resources, normalized_resources)

      {:ok, sanitized}
    end
  end

  defp optional_requirements(nil, _fingerprint), do: :ok
  defp optional_requirements(body, fingerprint) when is_map(body), do: optional_fingerprint(fingerprint)
  defp optional_requirements(_body, _fingerprint), do: {:error, :invalid_argument, %{argument: :requirements}}

  defp optional_text(nil, _key), do: :ok
  defp optional_text(value, key), do: present(value, key)

  defp optional_text_value(nil, _key), do: :ok
  defp optional_text_value(value, key) when is_binary(value), do: present(String.trim(value), key)
  defp optional_text_value(_value, key), do: {:error, :invalid_argument, %{argument: key}}

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

  defp optional_resources(nil), do: {:ok, nil}

  defp optional_resources(value) do
    case Resources.normalize_all(value) do
      {:ok, normalized} -> {:ok, normalized}
      _ -> {:error, :invalid_argument, %{argument: :resources}}
    end
  end

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

  defp duplicate_identity_free?(state, assignment),
    do: duplicate_identity_free_after_revision?(state, nil, assignment)

  defp duplicate_identity_free_after_revision?(state, own_id, assignment) do
    identity = assignment_identity(assignment)

    duplicate =
      Enum.find(state.assignments, fn {id, existing} ->
        id != own_id and assignment_identity(existing) == identity
      end)

    if is_nil(duplicate), do: :ok, else: {:error, :duplicate_underlying_identity, %{assignment_id: elem(duplicate, 0)}}
  end

  defp assignment_identity(assignment) when is_map(assignment) do
    provider = value_or_default(text_value(assignment, :provider), "github")

    case text_value(assignment, :native_issue_id) do
      nil ->
        repository = value_or_default(text_value(assignment, :repository), "")
        issue_number = value_or_default(number_value(assignment, :issue_number), 0)
        repository <> "#" <> Integer.to_string(issue_number)

      issue_id ->
        repository =
          value_or_default(text_value(assignment, :native_repository_id), text_value(assignment, :repository) || "")

        provider <> ":issue:" <> repository <> ":" <> issue_id
    end
  end

  defp resources_free?(state, resources, own_id \\ nil) do
    conflicting =
      Enum.find(state.assignments, fn {id, existing} ->
        id != own_id and resource_claiming?(existing) and resources_conflict?(resources, Map.get(existing, :resources, []))
      end)

    if is_nil(conflicting), do: :ok, else: {:error, :resource_conflict, %{assignment_id: elem(conflicting, 0)}}
  end

  @spec resources_available?(state(), map()) :: boolean()
  def resources_available?(state, assignment) when is_map(state) and is_map(assignment) do
    resources_free?(state, Map.get(assignment, :resources, []), Map.get(assignment, :assignment_id)) == :ok
  end

  def resources_available?(_state, _assignment), do: false

  defp resources_conflict?(resources, existing) do
    with {:ok, left} <- Resources.normalize_all(resources),
         {:ok, right} <- Resources.normalize_all(existing) do
      Enum.any?(left, fn candidate -> Enum.any?(right, &Resources.conflicts?(candidate, &1)) end)
    else
      _ -> true
    end
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

    event = Map.merge(event, Map.take(response, [:source_pm_id, :destination_pm_id, :assignment_ids, :reason, :handoff_id, :status]))

    next_state =
      next_state
      |> Map.put(:control_revision, control_revision)
      |> Map.put(:event_cursor, event_cursor)
      |> Map.put(:events, [event | Enum.take(Map.get(state, :events, []), 99)])
      |> put_in([:requests, request.request_id], request_record(request, canonical, response))
      |> trim_requests()

    {:ok, next_state, response}
  end

  defp request_record(request, canonical, response) do
    principal = Map.get(request, :principal)

    %{canonical: canonical, response: response}
    |> maybe_put(:principal_id, principal && principal.principal_id)
    |> maybe_put(:capability_id, principal && principal.capability_id)
  end

  defp request_principal_allowed?(record, principal) do
    case Map.get(record, :principal_id) do
      nil -> false
      value -> value == principal.principal_id
    end
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
  defp normalize_key("assignment_ids"), do: :assignment_ids
  defp normalize_key("assignments"), do: :assignments
  defp normalize_key("expected_ownership_revision"), do: :expected_ownership_revision
  defp normalize_key("expected_revisions"), do: :expected_revisions
  defp normalize_key("expected_ownership_revisions"), do: :expected_ownership_revisions
  defp normalize_key("project_id"), do: :project_id
  defp normalize_key("destination_pm_id"), do: :destination_pm_id
  defp normalize_key("project_item_id"), do: :project_item_id
  defp normalize_key("native_issue_id"), do: :native_issue_id
  defp normalize_key("native_repository_id"), do: :native_repository_id
  defp normalize_key("status_field_id"), do: :status_field_id
  defp normalize_key("projection_field_id"), do: :projection_field_id
  defp normalize_key("project_number"), do: :project_number
  defp normalize_key("status_options"), do: :status_options
  defp normalize_key("repositories"), do: :repositories
  defp normalize_key("repository"), do: :repository
  defp normalize_key("provider"), do: :provider
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
  defp normalize_key("principal"), do: :principal
  defp normalize_key("target_principal_id"), do: :target_principal_id
  defp normalize_key("handoff_id"), do: :handoff_id
  defp normalize_key("display_name"), do: :display_name
  defp normalize_key("scope"), do: :scope
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

  defp review_feedback_evidence(value) when is_list(value), do: :ok
  defp review_feedback_evidence(_value), do: {:error, :invalid_argument, %{argument: :evidence}}

  defp normalize_evidence(evidence), do: Enum.take(evidence, 20)

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
    |> Enum.reject(fn {key, _value} -> normalize_key(key) in [:requirements, :issue_body, :principal] end)
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
