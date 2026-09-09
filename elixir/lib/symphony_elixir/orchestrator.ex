defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.GitHubProjects.Client
  alias SymphonyElixir.Managed.{Checkout, Journal, Rules}
  alias SymphonyElixir.Tracker.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      managed: nil
    ]
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    case Config.settings() do
      {:ok, config} ->
        now_ms = System.monotonic_time(:millisecond)

        state = %State{
          poll_interval_ms: config.polling.interval_ms,
          max_concurrent_agents: config.agent.max_concurrent_agents,
          next_poll_due_at_ms: now_ms,
          poll_check_in_progress: false,
          tick_timer_ref: nil,
          tick_token: nil,
          task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
          codex_totals: @empty_codex_totals,
          codex_rate_limits: nil,
          managed: nil
        }

        case initialize_managed(config, state, opts) do
          {:ok, state} ->
            state = recover_managed_startup(state)

            if is_nil(state.managed), do: run_terminal_workspace_cleanup()
            state = schedule_tick(state, 0)
            {:ok, state}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp recover_managed_startup(%State{managed: nil} = state), do: state

  defp recover_managed_startup(%State{} = state) do
    state
    |> recover_managed_usage_inflight()
    |> recover_managed_active_assignments()
  end

  @impl true
  def terminate(_reason, %State{managed: %{journal: journal}}) do
    Journal.close(journal)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call(:managed_state, _from, %State{managed: nil} = state), do: {:reply, {:error, :managed_mode_disabled}, state}

  def handle_call(:managed_state, _from, %State{managed: %{data: data}} = state) do
    {:reply, {:ok, Rules.snapshot(data)}, state}
  end

  def handle_call({:managed_events, _after_cursor, _limit}, _from, %State{managed: nil} = state) do
    {:reply, {:error, :managed_mode_disabled}, state}
  end

  def handle_call({:managed_events, after_cursor, limit}, _from, %State{managed: %{data: data}} = state)
      when is_integer(after_cursor) and is_integer(limit) do
    events =
      data
      |> Map.get(:events, [])
      |> Enum.filter(&(is_map(&1) and Map.get(&1, :cursor, 0) > after_cursor))
      |> Enum.reverse()
      |> Enum.take(max(min(limit, 100), 0))

    {:reply, {:ok, events}, state}
  end

  def handle_call({:managed_control, _envelope}, _from, %State{managed: nil} = state) do
    {:reply, {:error, :managed_mode_disabled}, state}
  end

  def handle_call({:managed_reconcile, _assignment_id, _facts}, _from, %State{managed: nil} = state) do
    {:reply, {:error, :managed_mode_disabled}, state}
  end

  def handle_call({:managed_reconcile, assignment_id, facts}, _from, %State{managed: managed} = state)
      when is_binary(assignment_id) and is_map(facts) do
    case record_managed_reconciliation(managed.data, assignment_id, facts) do
      {:ok, data, response} ->
        case persist_managed_data(state, data) do
          {:ok, next_state} -> {:reply, {:ok, response}, next_state}
          {:error, reason} -> {:reply, {:error, :managed_journal_write_failed, %{reason: inspect(reason)}}, state}
        end

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:managed_session, _attempt, _info}, _from, %State{managed: nil} = state) do
    {:reply, {:error, :managed_mode_disabled}, state}
  end

  def handle_call({:managed_session, attempt, info}, _from, %State{managed: managed} = state)
      when is_map(attempt) and is_map(info) do
    case record_managed_session(managed.data, attempt, info) do
      {:ok, data} ->
        case persist_managed_data(state, data) do
          {:ok, next_state} -> {:reply, :ok, next_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, code, details} ->
        {:reply, {:error, {code, details}}, state}
    end
  end

  def handle_call({:managed_before_turn, _turn_context}, _from, %State{managed: nil} = state) do
    {:reply, {:stop, :managed_mode_disabled}, state}
  end

  def handle_call({:managed_before_turn, turn_context}, _from, %State{} = state)
      when is_map(turn_context) do
    {decision, next_state} = managed_before_turn(state, turn_context)
    {:reply, decision, next_state}
  end

  def handle_call({:managed_report, _payload}, _from, %State{managed: nil} = state) do
    {:reply, {:error, :managed_mode_disabled}, state}
  end

  def handle_call({:managed_report, payload}, _from, %State{managed: _managed} = state)
      when is_map(payload) do
    managed_report_call(state, payload)
  end

  def handle_call(:snapshot, from, state), do: snapshot_call(from, state)

  def handle_call(:request_refresh, from, state), do: request_refresh_call(from, state)

  def handle_call({:managed_control, envelope}, _from, %State{managed: %{data: data}} = state)
      when is_map(envelope) do
    cond do
      managed_binding_envelope?(envelope) -> handle_managed_binding_control(state, envelope)
      managed_review_envelope?(envelope) -> handle_managed_review_control(state, envelope)
      managed_transition_envelope?(envelope) -> handle_managed_transition_control(state, envelope)
      true -> apply_managed_control(state, envelope, managed_rules_context(data, envelope))
    end
  end

  defp managed_report_call(state, payload) do
    case managed_source_reconcile(state, payload) do
      {:ok, source_state, :unchanged} ->
        persist_managed_report(source_state, payload)

      {:ok, source_state, {:changed, target}} ->
        {:reply, {:error, {:managed_source_state_changed, target}}, source_state}

      {:error, source_state, reason} ->
        {:reply, {:error, reason}, source_state}
    end
  end

  defp persist_managed_report(state, payload) do
    case record_managed_report(state.managed.data, payload) do
      {:ok, report_data} -> persist_managed_report_data(state, report_data, payload)
      {:error, code, details} -> {:reply, {:error, {code, details}}, state}
    end
  end

  defp persist_managed_report_data(state, data, payload) do
    case persist_managed_data(state, data) do
      {:ok, next_state} -> report_provider_effect_reply(next_state, payload)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp report_provider_effect_reply(state, payload) do
    case managed_report_provider_effect(state, payload) do
      {:ok, provider_state} -> {:reply, :ok, provider_state}
      {:error, provider_state, {code, details}} -> {:reply, {:error, {code, details}}, provider_state}
    end
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = recover_managed_reviews(state)
    state = recover_managed_transitions(state)
    state = dispatch_cycle(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        next_state = %{state | running: Map.put(running, issue_id, updated_running_entry)}
        next_state = managed_record_runtime(next_state, issue_id, runtime_info)
        notify_dashboard()
        {:noreply, next_state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> Map.put(:running, Map.put(running, issue_id, updated_running_entry))
          |> managed_record_usage(issue_id, token_delta)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp managed_maybe_dispatch(%State{managed: %{data: data}} = state) do
    if data.paused == true or data.disabled == true or available_slots(state) <= 0 or
         managed_usage_exhausted?(data) do
      state
    else
      case Tracker.fetch_issues_by_states(["READY"]) do
        {:ok, issues} ->
          Enum.reduce(issues, state, &managed_dispatch_candidate(&2, &1))

        {:error, reason} ->
          Logger.warning("Managed dispatch refresh failed: #{inspect(reason)}")
          state
      end
    end
  end

  defp managed_maybe_dispatch(state), do: state

  defp managed_dispatch_candidate(%State{} = state, %Issue{id: issue_id} = issue)
       when is_binary(issue_id) do
    case get_in(state.managed, [:data, :assignments, issue_id]) do
      %{phase: :ready, board_state: :ready} = assignment ->
        if available_slots(state) > 0 and
             managed_issue_matches_assignment?(issue, assignment) and
             managed_dependencies_ready?(state.managed.data, assignment, issue) and
             not Map.has_key?(state.running, issue_id) do
          managed_start_assignment(state, issue, assignment)
        else
          state
        end

      _ ->
        state
    end
  end

  defp managed_dispatch_candidate(state, _issue), do: state

  defp managed_issue_matches_assignment?(%Issue{} = issue, assignment) do
    repository =
      get_in(issue.native_ref || %{}, ["repository", "name_with_owner"]) ||
        get_in(issue.native_ref || %{}, [:repository, :name_with_owner])

    number =
      get_in(issue.native_ref || %{}, ["issue_number"]) ||
        get_in(issue.native_ref || %{}, [:issue_number])

    issue.dispatchable == true and issue_state_ready?(issue.state) and
      issue_assignment_identity_matches?(repository, number, assignment)
  end

  defp issue_assignment_identity_matches?(repository, number, assignment) do
    repository == assignment.repository and number == assignment.issue_number
  end

  defp issue_state_ready?(state) when is_binary(state), do: String.downcase(String.trim(state)) == "ready"
  defp issue_state_ready?(_state), do: false

  defp managed_dependencies_ready?(data, assignment, issue) do
    explicit_ready? =
      Enum.all?(assignment[:dependencies] || [], fn id ->
        accepted_dependency_receipt?(data, id)
      end)

    native_ready? = native_dependencies_ready?(data, issue)

    explicit_ready? and native_ready?
  end

  defp native_dependencies_ready?(data, issue) do
    Enum.all?(issue.blocked_by || [], fn blocker -> native_dependency_ready?(data, blocker) end)
  end

  defp native_dependency_ready?(data, blocker) do
    with identity when is_binary(identity) <- native_blocker_identity(blocker),
         {id, _dependency} <- find_assignment_by_identity(data, identity) do
      accepted_dependency_receipt?(data, id)
    else
      _ -> false
    end
  end

  defp native_blocker_identity(%{"identifier" => identifier, "state" => state}) when is_binary(identifier) and is_binary(state) do
    if String.downcase(String.trim(state)) == "closed", do: identifier, else: nil
  end

  defp native_blocker_identity(_blocker), do: nil

  defp find_assignment_by_identity(data, identifier) when is_binary(identifier) do
    Enum.find(data.assignments, fn {_id, dependency} ->
      dependency.repository <> "#" <> Integer.to_string(dependency.issue_number) == identifier
    end)
  end

  defp accepted_dependency_receipt?(data, id) do
    assignment = get_in(data, [:assignments, id])
    reconciliation = get_in(data, [:external_reconciliations, id])

    accepted_assignment?(assignment) and
      accepted_reconciliation?(assignment, reconciliation) and
      accepted_external_effects?(reconciliation)
  end

  defp accepted_assignment?(assignment) when is_map(assignment) do
    assignment[:phase] == :accepted and
      is_list(assignment[:evidence]) and assignment[:evidence] != [] and
      is_binary(assignment[:requirements_fingerprint]) and assignment[:requirements_fingerprint] != "" and
      is_integer(assignment[:requirements_revision]) and assignment[:requirements_revision] >= 0
  end

  defp accepted_assignment?(_assignment), do: false

  defp accepted_reconciliation?(assignment, reconciliation) when is_map(reconciliation) do
    reconciliation[:reconciled] == true and
      reconciliation[:revision] in [assignment[:revision], assignment[:revision] - 1] and
      reconciliation[:provider_final_state] in [:accepted, "accepted"] and
      reconciliation[:issue_final_state] in [:closed, "closed"]
  end

  defp accepted_reconciliation?(_assignment, _reconciliation), do: false

  defp accepted_external_effects?(reconciliation) when is_map(reconciliation) do
    effects = reconciliation[:external_effects] || %{}

    is_map(effects) and effects[:status] in [:ok, "ok", :reconciled, "reconciled"] and
      effects[:issue_close] in [:ok, "ok", :reconciled, "reconciled"]
  end

  defp accepted_external_effects?(_reconciliation), do: false

  defp managed_start_assignment(%State{} = state, %Issue{} = issue, assignment) do
    case managed_checkout_options() do
      {:ok, _options} ->
        managed_start_assignment_ready(state, issue, assignment)

      {:error, reason} ->
        Logger.error("Managed dispatch blocked: #{inspect(reason)}")
        state
    end
  end

  defp managed_start_assignment_ready(%State{} = state, %Issue{id: issue_id} = issue, assignment) do
    generation =
      if assignment[:recovery_generation_pending] == true,
        do: Map.get(assignment, :generation, 0),
        else: Map.get(assignment, :generation, 0) + 1

    attempt_id = "managed-#{issue_id}-#{generation}-#{System.unique_integer([:positive])}"

    attempt = %{
      assignment_id: issue_id,
      revision: Map.get(assignment, :revision, 0),
      generation: generation,
      attempt_id: attempt_id,
      model: route_value(assignment.route, :model),
      effort: route_value(assignment.route, :effort),
      escalation_reason: assignment[:escalation_reason]
    }

    updated_assignment =
      assignment
      |> Map.merge(%{
        phase: :active,
        board_state: :active,
        generation: generation,
        attempt_id: attempt_id,
        pending_effect: %{kind: :start, status: :pending, at: DateTime.utc_now()},
        started_at: DateTime.utc_now(),
        recovery_generation_pending: false
      })

    data =
      state.managed.data
      |> put_in([:assignments, issue_id], updated_assignment)
      |> append_managed_event(%{
        operation: :dispatch,
        assignment_id: issue_id,
        attempt_id: attempt_id,
        phase: :active
      })

    case persist_managed_data(state, data) do
      {:ok, next_state} ->
        case managed_apply_provider_transition(next_state, updated_assignment, :active) do
          {:ok, provider_state} -> dispatch_managed_attempt(provider_state, issue, attempt)
          {:error, provider_state, reason} -> managed_mark_dispatch_failed(provider_state, issue_id, attempt, reason)
        end

      {:error, reason} ->
        Logger.error("Managed dispatch intent could not be persisted for #{issue_id}: #{inspect(reason)}")
        state
    end
  end

  defp managed_report_provider_effect(%State{} = state, payload) do
    kind = map_value(payload, :kind)

    target =
      case kind do
        "result" -> :review
        "context_needed" -> :waiting
        _ -> nil
      end

    assignment_id = map_value(map_value(payload, :attempt) || %{}, :assignment_id)
    assignment = get_in(state.managed.data, [:assignments, assignment_id])

    managed_report_provider_effect(state, assignment, assignment_id, target)
  end

  defp managed_report_provider_effect(state, _assignment, _assignment_id, nil), do: {:ok, state}

  defp managed_report_provider_effect(state, assignment, assignment_id, :waiting) do
    if Map.has_key?(state.running, assignment_id) do
      defer_managed_report(state, assignment, assignment_id)
    else
      managed_apply_provider_transition(state, assignment, :waiting)
    end
  end

  defp managed_report_provider_effect(state, assignment, _assignment_id, target) do
    managed_apply_provider_transition(state, assignment, target)
  end

  # A context-needed report is terminal for the worker, but its provider
  # transition must wait until the owned process has actually stopped.
  defp defer_managed_report(state, assignment, assignment_id) do
    with {:ok, intent_state, intent_id} <-
           ensure_managed_transition_intent(state, assignment, :waiting),
         data <-
           intent_state.managed.data
           |> put_in([:assignments, assignment_id, :stop_pending], true)
           |> put_in([:assignments, assignment_id, :pending_effect], %{
             kind: :report,
             status: :deferred,
             target: :waiting,
             request_id: intent_id
           })
           |> append_managed_event(%{
             operation: :provider_transition_deferred,
             assignment_id: assignment_id,
             target: :waiting,
             request_id: intent_id,
             reason: :process_not_stopped
           }),
         {:ok, deferred_state} <- persist_managed_data(intent_state, data) do
      {:ok, deferred_state}
    else
      {:error, failed_state, reason} -> {:error, failed_state, reason}
      {:error, reason} -> {:error, state, {:managed_journal_write_failed, reason}}
    end
  end

  defp managed_apply_provider_transition(%State{managed: %{effects: module}} = state, assignment, target)
       when is_atom(module) and is_map(assignment) and is_atom(target) do
    with true <- Code.ensure_loaded?(module) and function_exported?(module, :transition, 3),
         {:ok, intent_state, intent_id} <- ensure_managed_transition_intent(state, assignment, target) do
      context = %{
        binding: intent_state.managed.data[:binding],
        process_stopped: not Map.has_key?(intent_state.running, assignment.assignment_id)
      }

      apply_provider_transition_effect(intent_state, assignment, target, intent_id, module, context)
    else
      false ->
        {:error, state, {:managed_provider_effects_unavailable, %{}}}

      {:error, state, reason} ->
        {:error, state, reason}
    end
  end

  defp apply_provider_transition_effect(state, assignment, target, intent_id, module, context) do
    case safe_managed_effect_call(module, :transition, [assignment, target, context]) do
      {:ok, facts} when is_map(facts) ->
        persist_provider_transition(state, assignment, target, intent_id, facts)

      {:error, code, details} ->
        managed_provider_transition_failed(state, assignment, target, {code, details}, intent_id)

      {:error, reason} ->
        managed_provider_transition_failed(
          state,
          assignment,
          target,
          {:managed_provider_effect_failed, reason},
          intent_id
        )
    end
  end

  defp persist_provider_transition(state, assignment, target, intent_id, facts) do
    effect = %{
      kind: :provider_transition,
      target: target,
      status: :reconciled,
      facts: facts,
      at: DateTime.utc_now()
    }

    next_data =
      state.managed.data
      |> update_in([:assignments, assignment.assignment_id], fn current ->
        current
        |> Map.put(:pending_effect, effect)
        |> maybe_put_managed(
          :resume_ready,
          if(target == :active,
            do: current[:resume_ready],
            else: target in [:ready, :review, :waiting] and is_binary(current[:thread_id])
          )
        )
      end)
      |> update_in([:effect_intents, intent_id], fn existing ->
        (existing || %{})
        |> Map.put(:status, :effect_reconciled)
        |> Map.put(:facts, facts)
        |> Map.put(:effect_reconciled_at, DateTime.utc_now())
      end)
      |> append_managed_event(%{
        operation: :provider_transition,
        assignment_id: assignment.assignment_id,
        target: target,
        status: :reconciled,
        request_id: intent_id
      })

    case persist_managed_data(state, next_data) do
      {:ok, next_state} -> {:ok, next_state}
      {:error, reason} -> {:error, state, {:managed_journal_write_failed, reason}}
    end
  end

  defp ensure_managed_transition_intent(%State{} = state, assignment, target) do
    intents = state.managed.data[:effect_intents] || %{}

    case Enum.find(intents, fn {_id, intent} ->
           is_map(intent) and intent[:assignment_id] == assignment.assignment_id and
             intent[:target] == target and managed_transition_intent_reusable?(intent)
         end) do
      {intent_id, _intent} ->
        {:ok, state, intent_id}

      nil ->
        intent_id =
          "managed-effect-#{assignment.assignment_id}-#{target}-#{state.managed.data[:event_cursor] + 1}"

        intent = %{
          request_id: intent_id,
          request: nil,
          assignment_id: assignment.assignment_id,
          target: target,
          auto: true,
          status: :pending,
          at: DateTime.utc_now()
        }

        data =
          state.managed.data
          |> put_in([:effect_intents, intent_id], intent)
          |> append_managed_event(%{
            operation: :provider_transition_intent,
            request_id: intent_id,
            assignment_id: assignment.assignment_id,
            target: target
          })

        case persist_managed_data(state, data) do
          {:ok, next_state} -> {:ok, next_state, intent_id}
          {:error, reason} -> {:error, state, {:managed_journal_write_failed, reason}}
        end
    end
  end

  defp managed_transition_intent_reusable?(intent) when is_map(intent) do
    intent[:status] == :pending or
      (intent[:status] == :effect_reconciled and is_map(intent[:request]))
  end

  defp managed_transition_intent_reusable?(_intent), do: false

  defp managed_provider_transition_failed(%State{} = state, assignment, target, reason, intent_id) do
    data =
      state.managed.data
      |> update_in([:assignments, assignment.assignment_id, :pending_effect], fn _ ->
        %{
          kind: :provider_transition,
          target: target,
          status: :failed,
          error: managed_effect_error_code(reason),
          at: DateTime.utc_now()
        }
      end)
      |> update_in([:effect_intents, intent_id], fn existing ->
        (existing || %{})
        |> Map.put(:status, :pending)
        |> Map.put(:last_error, managed_effect_error_code(reason))
        |> Map.put(:last_error_at, DateTime.utc_now())
      end)
      |> append_managed_event(%{
        operation: :provider_transition_failed,
        assignment_id: assignment.assignment_id,
        target: target,
        error: managed_effect_error_code(reason),
        request_id: intent_id
      })

    case persist_managed_data(state, data) do
      {:ok, next_state} -> {:error, next_state, reason}
      {:error, _journal_reason} -> {:error, state, reason}
    end
  end

  defp managed_effect_error_code({code, _details}) when is_atom(code), do: code
  defp managed_effect_error_code(_reason), do: :managed_provider_effect_failed

  defp safe_managed_effect_call(module, function, args) do
    apply(module, function, args)
  rescue
    error -> {:error, :managed_provider_effect_failed, %{reason: Exception.message(error)}}
  catch
    kind, reason -> {:error, :managed_provider_effect_failed, %{reason: inspect({kind, reason})}}
  end

  defp dispatch_managed_attempt(%State{} = state, %Issue{} = issue, attempt) do
    recipient = self()

    state =
      case select_worker_host(state, nil) do
        :no_worker_capacity -> state
        worker_host -> spawn_issue_on_worker_host(state, issue, nil, recipient, worker_host)
      end

    case Map.get(state.running, issue.id) do
      %{pid: pid} ->
        data = managed_dispatch_started_data(state.managed.data, issue.id, pid, attempt.attempt_id)

        case persist_managed_data(state, data) do
          {:ok, next_state} ->
            next_state

          {:error, reason} ->
            Logger.error("Managed dispatch result could not be persisted for #{issue.id}: #{inspect(reason)}")
            state
        end

      _ ->
        managed_mark_dispatch_failed(state, issue.id, attempt, :spawn_failed)
    end
  end

  defp managed_dispatch_started_data(data, issue_id, pid, attempt_id) do
    data
    |> update_in([:assignments, issue_id], fn assignment ->
      if is_map(assignment) do
        assignment
        |> Map.put(:resume_ready, false)
        |> Map.put(:pending_effect, %{
          kind: :start,
          status: :started,
          process_id: inspect(pid),
          attempt_id: attempt_id
        })
      else
        assignment
      end
    end)
    |> append_managed_event(%{
      operation: :dispatch_started,
      assignment_id: issue_id,
      attempt_id: attempt_id
    })
  end

  defp managed_mark_dispatch_failed(%State{} = state, issue_id, attempt, reason) do
    assignment = get_in(state.managed.data, [:assignments, issue_id])
    retry_count = managed_dispatch_retry_count(assignment)
    retry_allowed? = is_map(assignment) and managed_retry_allowed?(Map.put(assignment, :retry_count, retry_count))
    next_retry_count = retry_count + 1
    phase = if retry_allowed?, do: :ready, else: :waiting
    blocked_reason = if phase == :waiting, do: inspect(reason), else: nil

    data =
      state.managed.data
      |> update_in([:assignments, issue_id], fn assignment ->
        if is_map(assignment) do
          assignment
          |> Map.put(:phase, phase)
          |> Map.put(:board_state, phase)
          |> Map.put(:retry_count, next_retry_count)
          |> maybe_put_managed(:blocked_reason, blocked_reason)
          |> managed_dispatch_failure_effect(attempt, reason, retry_allowed?)
        else
          assignment
        end
      end)
      |> append_managed_event(%{
        operation: :dispatch_failed,
        assignment_id: issue_id,
        attempt_id: attempt.attempt_id,
        phase: phase,
        retry_count: next_retry_count,
        reason: inspect(reason)
      })

    case persist_managed_data(state, data) do
      {:ok, next_state} -> next_state
      {:error, _reason} -> state
    end
  end

  defp managed_dispatch_retry_count(assignment) when is_map(assignment) do
    case assignment[:retry_count] do
      retry_count when is_integer(retry_count) and retry_count >= 0 -> retry_count
      _ -> 0
    end
  end

  defp managed_dispatch_retry_count(_assignment), do: 0

  defp managed_dispatch_failure_effect(assignment, attempt, reason, retry_allowed?) do
    case assignment[:pending_effect] do
      %{kind: :provider_transition} ->
        assignment

      _ ->
        status = if retry_allowed?, do: :retry_pending, else: :failed

        Map.put(assignment, :pending_effect, %{
          kind: :start,
          status: status,
          reason: inspect(reason),
          attempt_id: attempt.attempt_id
        })
    end
  end

  defp record_managed_reconciliation(data, assignment_id, facts) do
    case Map.fetch(data.assignments, assignment_id) do
      :error ->
        {:error, :assignment_not_found, %{assignment_id: assignment_id}}

      {:ok, assignment} ->
        revision = map_value(facts, :revision)

        cond do
          not is_nil(revision) and revision != assignment.revision ->
            {:error, :stale_revision, %{expected: revision, actual: assignment.revision}}

          not is_nil(map_value(facts, :external_effects)) and
              not is_map(map_value(facts, :external_effects)) ->
            {:error, :invalid_argument, %{argument: :external_effects}}

          true ->
            reconciliation =
              facts
              |> Map.take([
                :provider_state,
                :provider_final_state,
                :issue_final_state,
                :external_effects,
                :reconciled,
                :stop_reconciled,
                :review_request_id,
                :observed_issue_id,
                :observed_project_item_id
              ])
              |> Map.put(:revision, assignment.revision)
              |> Map.put(:at, DateTime.utc_now())

            data =
              data
              |> Map.put(
                :external_reconciliations,
                Map.put(data[:external_reconciliations] || %{}, assignment_id, reconciliation)
              )
              |> append_managed_event(%{
                operation: :reconcile,
                assignment_id: assignment_id,
                revision: assignment.revision
              })

            {:ok, data,
             %{
               assignment_id: assignment_id,
               revision: assignment.revision,
               reconciled: reconciliation[:reconciled] == true
             }}
        end
    end
  end

  defp managed_finalize_usage(usage, running_entry, previous_usage_total, limit)
       when is_map(usage) and is_map(running_entry) do
    observed_total = nonnegative_integer(running_entry[:codex_total_tokens], 0)
    previous_total = nonnegative_integer(previous_usage_total, 0)
    additional = max(observed_total - previous_total, 0)
    cumulative = nonnegative_integer(usage[:cumulative_tokens], 0) + additional
    inflight = max(nonnegative_integer(usage[:inflight_tokens], 0) - observed_total, 0)

    %{
      baseline_tokens: nonnegative_integer(usage[:baseline_tokens], 0),
      cumulative_tokens: cumulative,
      inflight_tokens: inflight,
      overshoot_tokens: max(nonnegative_integer(usage[:overshoot_tokens], 0), 0),
      cap_reached: usage[:cap_reached] == true
    }
    |> then(fn next_usage ->
      if is_integer(limit) and limit > 0 do
        Map.merge(next_usage, %{
          overshoot_tokens: max(cumulative - limit, 0),
          cap_reached: cumulative >= limit
        })
      else
        next_usage
      end
    end)
  end

  defp managed_finalize_usage(usage, _running_entry, _previous_usage_total, _limit) when is_map(usage), do: usage
  defp managed_finalize_usage(_usage, _running_entry, _previous_usage_total, _limit), do: %{}

  defp managed_usage_exhausted?(data) when is_map(data) do
    limit = data[:usage_limit_tokens]
    usage = data[:usage] || %{}
    cumulative = usage[:cumulative_tokens] || 0
    is_integer(limit) and limit > 0 and is_integer(cumulative) and cumulative >= limit
  end

  defp managed_usage_exhausted?(_data), do: false

  defp managed_record_usage(%State{managed: %{data: data}} = state, issue_id, token_delta)
       when is_binary(issue_id) and is_map(token_delta) do
    case token_delta[:total_tokens] do
      total when is_integer(total) and total > 0 ->
        record_managed_usage_for_assignment(state, data, issue_id, token_delta, total)

      _ ->
        state
    end
  end

  defp managed_record_usage(state, _issue_id, _token_delta), do: state

  defp record_managed_usage_for_assignment(state, data, issue_id, token_delta, total) do
    case get_in(data, [:assignments, issue_id]) do
      assignment when is_map(assignment) ->
        assignment_usage = assignment[:usage] || %{}
        previous_total = nonnegative_integer(assignment_usage[:total_tokens], 0)
        usage = data[:usage] || %{}
        cumulative = nonnegative_integer(usage[:cumulative_tokens], 0) + total
        limit = data[:usage_limit_tokens]
        overshoot = if is_integer(limit) and limit > 0, do: max(cumulative - limit, 0), else: 0

        next_usage = %{
          input_tokens:
            nonnegative_integer(assignment_usage[:input_tokens], 0) +
              nonnegative_integer(token_delta[:input_tokens], 0),
          output_tokens:
            nonnegative_integer(assignment_usage[:output_tokens], 0) +
              nonnegative_integer(token_delta[:output_tokens], 0),
          total_tokens: previous_total + total,
          seconds_running: nonnegative_integer(assignment_usage[:seconds_running], 0),
          attempt_id: get_in(assignment, [:attempt_id])
        }

        next_aggregate = %{
          baseline_tokens: nonnegative_integer(usage[:baseline_tokens], 0),
          cumulative_tokens: cumulative,
          inflight_tokens: nonnegative_integer(usage[:inflight_tokens], 0) + total,
          overshoot_tokens: overshoot,
          cap_reached: is_integer(limit) and limit > 0 and cumulative >= limit
        }

        next_data =
          data
          |> put_in([:assignments, issue_id, :usage], next_usage)
          |> Map.put(:usage, next_aggregate)

        persist_managed_usage(state, next_data, issue_id)

      _ ->
        state
    end
  end

  defp persist_managed_usage(state, data, issue_id) do
    case persist_managed_data(state, data) do
      {:ok, next_state} ->
        next_state

      {:error, reason} ->
        Logger.error("Managed usage could not be persisted for #{issue_id}: #{inspect(reason)}")
        state
    end
  end

  defp managed_record_runtime(%State{managed: %{data: data}} = state, issue_id, runtime_info)
       when is_map(runtime_info) do
    case get_in(data, [:assignments, issue_id]) do
      assignment when is_map(assignment) ->
        patch =
          runtime_info
          |> Map.take([:worker_host, :workspace_path, :codex_app_server_pid])
          |> Map.put(:runtime_identity, Map.get(runtime_info, :attempt))

        next_data = put_in(data, [:assignments, issue_id], Map.merge(assignment, patch))

        case persist_managed_data(state, next_data) do
          {:ok, next_state} -> next_state
          {:error, _reason} -> state
        end

      _ ->
        state
    end
  end

  defp managed_record_runtime(state, _issue_id, _runtime_info), do: state

  defp record_managed_session(data, attempt, info) do
    assignment_id = map_value(attempt, :assignment_id)

    with {:ok, assignment} <- Map.fetch(data.assignments, assignment_id),
         :ok <- managed_attempt_matches?(assignment, attempt),
         thread_id when is_binary(thread_id) <- map_value(info, :thread_id) do
      patch =
        info
        |> Map.take([:thread_id, :workspace, :worker_host, :model, :effort, :thread_reasoning_effort, :metadata])
        |> Map.put(:session_id, thread_id)
        |> Map.put(:pending_effect, %{kind: :start, status: :session_started, thread_id: thread_id})

      data =
        data
        |> put_in([:assignments, assignment_id], Map.merge(assignment, patch))
        |> append_managed_event(%{operation: :session_started, assignment_id: assignment_id, thread_id: thread_id})

      {:ok, data}
    else
      :error -> {:error, :assignment_not_found, %{assignment_id: assignment_id}}
      {:error, code, details} -> {:error, code, details}
      _ -> {:error, :invalid_session_info, %{}}
    end
  end

  defp managed_before_turn(%State{managed: %{data: _data}} = state, turn_context) do
    case managed_source_reconcile(state, turn_context) do
      {:ok, reconciled_state, :unchanged} ->
        decision =
          if managed_usage_exhausted?(reconciled_state.managed.data) do
            {:stop, :managed_usage_limit_exhausted}
          else
            managed_before_turn_decision(reconciled_state.managed.data, turn_context)
          end

        case decision do
          :allow -> managed_reserve_turn(reconciled_state, turn_context)
          _ -> {decision, reconciled_state}
        end

      {:ok, reconciled_state, {:changed, target}} ->
        {{:stop, {:managed_source_state_changed, target}}, reconciled_state}

      {:error, reconciled_state, reason} ->
        {{:stop, reason}, reconciled_state}
    end
  end

  defp managed_before_turn(state, _turn_context), do: {{:stop, :managed_mode_disabled}, state}

  defp managed_reserve_turn(%State{managed: %{data: data}} = state, turn_context) do
    attempt = map_value(turn_context, :attempt)
    assignment_id = map_value(attempt || %{}, :assignment_id)
    assignment = get_in(data, [:assignments, assignment_id])
    reserved = Map.get(assignment, :turns_reserved, 0)
    limit = Map.get(assignment, :turn_limit, 20)

    if is_integer(reserved) and is_integer(limit) and reserved < limit do
      updated = Map.put(assignment, :turns_reserved, reserved + 1)

      next_data =
        data
        |> put_in([:assignments, assignment_id], updated)
        |> append_managed_event(%{
          operation: :turn_reserved,
          assignment_id: assignment_id,
          attempt_id: map_value(attempt, :attempt_id),
          turns_reserved: reserved + 1,
          turn_limit: limit
        })

      case persist_managed_data(state, next_data) do
        {:ok, next_state} -> {:allow, next_state}
        {:error, reason} -> {{:stop, {:managed_journal_write_failed, reason}}, state}
      end
    else
      {{:stop, :managed_turn_budget_exhausted}, state}
    end
  end

  defp managed_before_turn_decision(data, turn_context) do
    attempt = map_value(turn_context, :attempt)
    assignment_id = map_value(attempt || %{}, :assignment_id)

    with {:ok, assignment} <- Map.fetch(data.assignments, assignment_id),
         :ok <- managed_attempt_matches?(assignment, attempt) do
      cond do
        data[:disabled] == true -> {:stop, :managed_disabled}
        assignment[:stop_pending] == true -> {:stop, :managed_stop_pending}
        assignment[:phase] != :active -> {:stop, {:managed_phase_changed, assignment[:phase]}}
        true -> :allow
      end
    else
      :error -> {:stop, :managed_assignment_not_found}
      {:error, code, _details} -> {:stop, code}
    end
  end

  defp record_managed_report(data, payload) do
    attempt = map_value(payload, :attempt)
    assignment_id = map_value(attempt || %{}, :assignment_id)
    report_id = map_value(payload, :report_id)
    kind = map_value(payload, :kind)
    summary = map_value(payload, :summary)
    evidence = map_value(payload, :evidence)

    with {:ok, assignment} <- Map.fetch(data.assignments, assignment_id),
         :ok <- managed_attempt_matches?(assignment, attempt),
         :ok <- valid_managed_report(kind, report_id, summary, evidence) do
      reports = assignment[:reports] || %{}
      canonical = %{report_id: report_id, kind: kind, summary: String.slice(summary, 0, 2_000), evidence: Enum.take(evidence, 20)}

      case Map.get(reports, report_id) do
        ^canonical ->
          {:ok, data}

        existing when is_map(existing) ->
          {:error, :report_id_conflict, %{report_id: report_id}}

        nil ->
          updated =
            assignment
            |> Map.put(:reports, Map.put(reports, report_id, canonical))
            |> Map.put(:last_report, canonical)
            |> managed_report_phase(kind, summary)

          data =
            data
            |> put_in([:assignments, assignment_id], updated)
            |> append_managed_event(%{
              operation: :report,
              assignment_id: assignment_id,
              report_id: report_id,
              kind: kind,
              phase: updated[:phase]
            })

          {:ok, data}
      end
    else
      :error -> {:error, :assignment_not_found, %{assignment_id: assignment_id}}
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp managed_report_phase(assignment, "result", _summary) do
    Map.merge(assignment, %{phase: :review, board_state: :review, pending_effect: %{kind: :report, status: :received}})
  end

  defp managed_report_phase(assignment, "context_needed", summary) do
    Map.merge(assignment, %{
      phase: :waiting,
      board_state: :waiting,
      blocked_reason: summary,
      stop_pending: true,
      pending_effect: %{kind: :report, status: :received}
    })
  end

  defp managed_report_phase(assignment, _kind, _summary), do: assignment

  defp valid_managed_report(kind, report_id, summary, evidence)
       when kind in ["result", "checkpoint", "context_needed"] and is_binary(report_id) and
              byte_size(report_id) > 0 and is_binary(summary) and is_list(evidence),
       do: :ok

  defp valid_managed_report(_kind, _report_id, _summary, _evidence),
    do: {:error, :invalid_managed_report, %{}}

  defp managed_attempt_matches?(assignment, attempt) when is_map(assignment) and is_map(attempt) do
    Enum.all?([:assignment_id, :revision, :generation, :attempt_id], fn key ->
      map_value(attempt, key) == Map.get(assignment, key)
    end)
    |> if(do: :ok, else: {:error, :stale_managed_attempt, %{}})
  end

  defp managed_attempt_matches?(_assignment, _attempt), do: {:error, :invalid_managed_attempt, %{}}

  defp managed_source_reconcile(%State{} = state, context) when is_map(context) do
    attempt = map_value(context, :attempt) || context
    assignment_id = map_value(attempt, :assignment_id)
    assignment = get_in(state.managed.data, [:assignments, assignment_id])

    cond do
      not is_map(assignment) ->
        {:error, state, :managed_assignment_not_found}

      not managed_source_fetch_enabled?() ->
        {:ok, state, :unchanged}

      true ->
        fetcher = Map.get(state.managed, :source_fetcher, &Tracker.fetch_issues_by_ids/1)

        case safe_managed_source_fetch(fetcher, [assignment_id]) do
          {:ok, [%Issue{} = issue]} ->
            managed_reconcile_source_issue(state, assignment, issue)

          {:ok, []} ->
            {:error, state, :managed_source_item_not_found}

          {:ok, _items} ->
            {:error, state, :managed_source_item_ambiguous}

          {:error, reason} ->
            {:error, state, {:managed_source_reconcile_failed, reason}}
        end
    end
  end

  defp managed_source_reconcile(state, _context), do: {:error, state, :managed_source_context_invalid}

  defp managed_source_fetch_enabled? do
    case Config.settings() do
      {:ok, %{tracker: %{kind: "github_projects"}}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp safe_managed_source_fetch(fetcher, ids) when is_function(fetcher, 1) do
    fetcher.(ids)
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_managed_source_fetch(_fetcher, _ids), do: {:error, :managed_source_fetcher_unavailable}

  defp managed_reconcile_source_issue(%State{} = state, assignment, %Issue{} = issue) do
    with :ok <- managed_source_identity_matches?(assignment, issue),
         :ok <- managed_source_material_matches?(assignment, issue),
         {:ok, target} <- managed_source_target(issue) do
      reconcile_source_observation(state, assignment, issue, target)
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp reconcile_source_observation(state, assignment, issue, target) do
    observed_issue_id = source_native_value(issue, :issue_id)
    observed_repository_id = source_native_repository_id(issue)
    observed_project_item_id = source_native_value(issue, :project_item_id)
    stop_pending = assignment[:stop_pending] == true or target != assignment[:phase]

    if source_observation_changed?(
         assignment,
         issue,
         target,
         observed_issue_id,
         observed_repository_id,
         observed_project_item_id
       ) do
      persist_source_observation(
        state,
        assignment,
        issue,
        target,
        observed_issue_id,
        observed_repository_id,
        observed_project_item_id,
        stop_pending
      )
    else
      {:ok, state, :unchanged}
    end
  end

  defp source_observation_changed?(assignment, issue, target, issue_id, repository_id, project_item_id) do
    target != assignment[:phase] or assignment[:stop_pending] == true or
      assignment[:source_authoritative] != true or assignment[:source_state] != issue.state or
      assignment[:native_issue_id] != issue_id or assignment[:native_repository_id] != repository_id or
      assignment[:project_item_id] != project_item_id
  end

  defp persist_source_observation(
         state,
         assignment,
         issue,
         target,
         observed_issue_id,
         observed_repository_id,
         observed_project_item_id,
         stop_pending
       ) do
    assignment_id = assignment.assignment_id

    updated =
      assignment
      |> Map.merge(%{
        phase: target,
        board_state: target,
        source_authoritative: true,
        source_state: issue.state,
        source_observed_at: DateTime.utc_now(),
        native_issue_id: observed_issue_id || assignment[:native_issue_id],
        native_repository_id: observed_repository_id || assignment[:native_repository_id],
        project_item_id: observed_project_item_id || assignment[:project_item_id],
        stop_pending: stop_pending,
        pending_effect: %{kind: :source_reconcile, status: :reconciled, target: target}
      })

    data =
      state.managed.data
      |> put_in([:assignments, assignment_id], updated)
      |> append_managed_event(%{
        operation: :source_reconcile,
        assignment_id: assignment_id,
        source_state: issue.state,
        target: target,
        stop_pending: stop_pending
      })

    case persist_managed_data(state, data) do
      {:ok, reconciled_state} ->
        next_state =
          if stop_pending,
            do: managed_stop_owned_process(reconciled_state, assignment_id),
            else: reconciled_state

        result =
          if target == assignment[:phase] and not stop_pending,
            do: :unchanged,
            else: {:changed, target}

        {:ok, next_state, result}

      {:error, reason} ->
        {:error, state, {:managed_journal_write_failed, reason}}
    end
  end

  defp managed_source_identity_matches?(assignment, %Issue{} = issue) do
    repository = source_native_value(issue, :repository) |> source_nested_value(:name_with_owner)
    issue_number = source_native_value(issue, :issue_number)
    content_type = source_native_value(issue, :content_type)
    expected_issue_id = assignment[:native_issue_id]
    expected_repository_id = assignment[:native_repository_id] || assignment[:repository_id]
    expected_project_item_id = assignment[:project_item_id] || assignment[:assignment_id]
    observed_issue_id = source_native_value(issue, :issue_id)
    observed_repository_id = source_native_value(issue, :repository) |> source_nested_value(:id)
    observed_project_item_id = source_native_value(issue, :project_item_id)

    if content_type == "Issue" and repository == assignment[:repository] and
         issue_number == assignment[:issue_number] and
         optional_identity_matches?(expected_issue_id, observed_issue_id) and
         optional_identity_matches?(expected_repository_id, observed_repository_id) and
         optional_identity_matches?(expected_project_item_id, observed_project_item_id) do
      :ok
    else
      {:error, :managed_source_identity_mismatch}
    end
  end

  defp optional_identity_matches?(nil, _observed), do: true
  defp optional_identity_matches?(expected, observed), do: expected == observed

  defp managed_source_material_matches?(assignment, %Issue{} = issue) do
    expected = assignment[:requirements_fingerprint]

    cond do
      is_nil(expected) ->
        :ok

      not is_binary(expected) or not String.starts_with?(expected, "sha256:") ->
        {:error, :managed_source_material_invalid}

      managed_material_fingerprint(issue.description) == expected ->
        :ok

      true ->
        {:error, :managed_source_material_changed}
    end
  end

  defp managed_material_fingerprint(body) when is_binary(body) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end

  defp managed_material_fingerprint(_body), do: managed_material_fingerprint("")

  defp managed_source_target(%Issue{} = issue) do
    native_state = source_native_value(issue, :issue_state) |> to_string() |> String.downcase()
    target = Rules.phase(issue.state)

    cond do
      native_state not in ["", "open"] -> {:ok, :cancelled}
      target in [:ready, :active, :waiting, :review, :cancelled] -> {:ok, target}
      true -> {:error, :managed_source_state_unknown}
    end
  end

  defp source_native_value(%Issue{native_ref: native}, key) when is_map(native) do
    Map.get(native, Atom.to_string(key), Map.get(native, key))
  end

  defp source_native_value(_issue, _key), do: nil

  defp source_nested_value(value, key) when is_map(value) do
    Map.get(value, Atom.to_string(key), Map.get(value, key))
  end

  defp source_nested_value(_value, _key), do: nil

  defp source_native_repository_id(%Issue{} = issue) do
    issue
    |> source_native_value(:repository)
    |> source_nested_value(:id)
  end

  defp managed_stop_owned_process(%State{} = state, assignment_id) do
    case Map.get(state.running, assignment_id) do
      %{pid: pid} when is_pid(pid) ->
        Process.exit(pid, :shutdown)
        state

      _ ->
        state
    end
  end

  defp managed_rules_context(data, envelope) do
    args = map_value(envelope, :args) || %{}
    assignment_id = map_value(args, :assignment_id)
    Map.get(data[:external_reconciliations] || %{}, assignment_id, %{})
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp map_value(_map, _key), do: nil

  defp route_value(route, key) when is_map(route), do: Map.get(route, key, Map.get(route, Atom.to_string(key)))
  defp route_value(_route, _key), do: nil

  defp recover_managed_reviews(%State{managed: %{data: data}} = state) do
    data[:review_intents]
    |> Enum.filter(fn {_request_id, intent} -> is_map(intent) and intent[:status] == :pending and is_map(intent[:request]) end)
    |> Enum.reduce(state, &recover_managed_review_intent/2)
  end

  defp recover_managed_reviews(state), do: state

  defp recover_managed_review_intent({_request_id, intent}, state) do
    case Rules.prepare_review(state.managed.data, intent.request) do
      {:ok, prepared} -> recover_prepared_managed_review(state, prepared)
      {:duplicate, _response} -> recover_duplicate_managed_review(state, intent)
      {:error, _code, _details} -> state
    end
  end

  defp recover_prepared_managed_review(state, prepared) do
    {:reply, _reply, next_state} = execute_managed_review(state, prepared)
    next_state
  end

  defp recover_duplicate_managed_review(state, intent) do
    committed = complete_managed_review_intent(state.managed.data, intent.request.request_id)

    case persist_managed_data(state, committed) do
      {:ok, next_state} -> next_state
      {:error, _reason} -> state
    end
  end

  defp recover_managed_usage_inflight(%State{managed: %{data: data}} = state) do
    usage = data[:usage] || %{}
    stale_inflight = nonnegative_integer(usage[:inflight_tokens], 0)

    if stale_inflight == 0 do
      state
    else
      recovered_data =
        data
        |> put_in([:usage, :inflight_tokens], 0)
        |> append_managed_event(%{
          operation: :startup_usage_recovery,
          stale_inflight_tokens: stale_inflight
        })

      case persist_managed_data(state, recovered_data) do
        {:ok, recovered_state} ->
          recovered_state

        {:error, reason} ->
          Logger.error("Managed startup usage recovery could not be persisted: #{inspect(reason)}")
          state
      end
    end
  end

  defp recover_managed_usage_inflight(state), do: state

  defp recover_managed_active_assignments(%State{managed: %{data: data}} = state) do
    data.assignments
    |> Enum.filter(fn {assignment_id, assignment} ->
      is_binary(assignment_id) and is_map(assignment) and assignment[:phase] == :active and
        not Map.has_key?(state.running, assignment_id)
    end)
    |> Enum.reduce(state, &recover_managed_active_assignment/2)
  end

  defp recover_managed_active_assignments(state), do: state

  defp recover_managed_active_assignment({assignment_id, assignment}, state) do
    case managed_source_reconcile(state, %{assignment_id: assignment_id}) do
      {:ok, reconciled_state, :unchanged} ->
        recover_managed_active_assignment_state(reconciled_state, assignment_id, assignment)

      {:ok, reconciled_state, _changed} ->
        reconciled_state

      {:error, reconciled_state, _reason} ->
        reconciled_state
    end
  end

  defp recover_managed_active_assignment_state(state, assignment_id, assignment) do
    current = get_in(state.managed.data, [:assignments, assignment_id]) || assignment

    resumed =
      Map.merge(current, %{
        phase: :ready,
        board_state: :ready,
        # The old process is absent after a restart, so the stop is
        # confirmed before any provider mutation or new dispatch.
        stop_pending: false,
        stop_reconciled: true,
        pending_effect: %{kind: :startup_recovery, status: :pending},
        generation: (current[:generation] || 0) + 1,
        attempt_id: nil,
        recovery_generation_pending: true,
        resume_ready: is_binary(current[:thread_id])
      })

    recovery_data =
      state.managed.data
      |> put_in([:assignments, assignment_id], resumed)
      |> append_managed_event(%{
        operation: :startup_recovery,
        assignment_id: assignment_id,
        generation: resumed[:generation],
        stop_reconciled: true,
        resume_ready: resumed[:resume_ready]
      })

    case persist_managed_data(state, recovery_data) do
      {:ok, next_state} -> apply_managed_recovery_transition(next_state, resumed)
      {:error, _reason} -> state
    end
  end

  defp apply_managed_recovery_transition(state, assignment) do
    case managed_apply_provider_transition(state, assignment, :ready) do
      {:ok, provider_state} -> provider_state
      {:error, provider_state, _reason} -> provider_state
    end
  end

  defp recover_managed_transitions(%State{managed: %{data: data}} = state) do
    data[:effect_intents]
    |> Enum.filter(fn {_request_id, intent} ->
      managed_transition_intent_reusable?(intent)
    end)
    |> Enum.reduce(state, &recover_managed_transition/2)
  end

  defp recover_managed_transitions(state), do: state

  defp recover_managed_transition({_request_id, intent}, state) do
    assignment = get_in(state.managed.data, [:assignments, intent.assignment_id])

    if is_map(assignment) do
      replay_managed_transition(state, assignment, intent)
    else
      state
    end
  end

  defp replay_managed_transition(state, assignment, %{request: request} = intent) when is_map(request) do
    {:reply, _reply, next_state} = execute_managed_transition(state, assignment, intent, %{})
    next_state
  end

  defp replay_managed_transition(state, assignment, intent) do
    # Automatic intents (dispatch/report/recovery transitions) have no control
    # request to replay. Re-apply the idempotent provider transition so a crash
    # between journaling and the effect cannot leave the intent pending forever.
    case managed_apply_provider_transition(state, assignment, intent[:target]) do
      {:ok, next_state} -> next_state
      {:error, next_state, _reason} -> next_state
    end
  end

  defp managed_binding_envelope?(envelope) when is_map(envelope) do
    map_value(envelope, :operation) in [:bind_project, "bind_project"]
  end

  defp handle_managed_binding_control(%State{} = state, envelope) do
    case managed_validate_binding(state, envelope) do
      :ok -> apply_managed_control(state, envelope, %{})
      {:error, code, details} -> {:reply, {:error, code, details}, state}
    end
  end

  defp managed_validate_binding(%State{managed: %{effects: effects}} = _state, _envelope)
       when effects != SymphonyElixir.Managed.GitHubEffects,
       do: :ok

  defp managed_validate_binding(%State{} = _state, envelope) do
    args = map_value(envelope, :args) || %{}
    requested = map_value(args, :project) || args

    with {:ok, configured} <- Client.fetch_configured_binding(),
         :ok <- compare_managed_binding(requested, configured) do
      :ok
    else
      {:error, code, details} -> {:error, code, details}
      {:error, reason} -> {:error, :managed_binding_validation_failed, %{reason: inspect(reason)}}
    end
  end

  defp compare_managed_binding(requested, configured) when is_map(requested) and is_map(configured) do
    fields = [:project_id, :project_number, :status_field_id]

    if Enum.all?(fields, fn key -> map_value(requested, key) == Map.get(configured, key) end) and
         status_options_match?(map_value(requested, :status_options), configured[:status_options]) do
      :ok
    else
      {:error, :managed_binding_mismatch, %{configured: Map.take(configured, fields)}}
    end
  end

  defp compare_managed_binding(_requested, _configured), do: {:error, :managed_binding_mismatch, %{}}

  defp status_options_match?(requested, configured) when is_map(requested) and is_map(configured) do
    requested_pairs =
      requested
      |> Enum.map(fn {name, id} -> {String.upcase(to_string(name)), to_string(id)} end)
      |> MapSet.new()

    configured_pairs =
      configured
      |> Enum.map(fn {name, id} -> {String.upcase(to_string(name)), to_string(id)} end)
      |> MapSet.new()

    MapSet.equal?(requested_pairs, configured_pairs)
  end

  defp status_options_match?(_requested, _configured), do: false

  defp managed_review_envelope?(envelope) when is_map(envelope) do
    Map.get(envelope, :operation, Map.get(envelope, "operation")) in [:review, "review"]
  end

  defp managed_transition_envelope?(envelope) when is_map(envelope) do
    Map.get(envelope, :operation, Map.get(envelope, "operation")) in [:revise, "revise", :interrupt, "interrupt", :cancel, "cancel"]
  end

  defp transition_target(envelope) do
    case Map.get(envelope, :operation, Map.get(envelope, "operation")) do
      operation when operation in [:revise, "revise"] -> :ready
      operation when operation in [:interrupt, "interrupt"] -> :waiting
      operation when operation in [:cancel, "cancel"] -> :cancelled
      _ -> nil
    end
  end

  defp handle_managed_transition_control(%State{} = state, envelope) do
    target = transition_target(envelope)
    assignment_id = map_value(map_value(envelope, :args) || %{}, :assignment_id)
    request_id = map_value(envelope, :request_id)
    current_assignment = get_in(state.managed.data, [:assignments, assignment_id])

    case get_in(state.managed.data, [:effect_intents, request_id]) do
      existing when is_map(existing) ->
        handle_existing_managed_transition(state, current_assignment, existing, request_id)

      _ ->
        prepare_managed_transition(state, envelope, current_assignment, target, assignment_id, request_id)
    end
  end

  defp handle_existing_managed_transition(state, assignment, intent, request_id) do
    if intent[:status] in [:pending, :effect_reconciled] do
      execute_managed_transition(state, assignment, intent, %{})
    else
      {:reply, {:error, :request_id_conflict, %{request_id: request_id}}, state}
    end
  end

  defp prepare_managed_transition(state, envelope, assignment, target, assignment_id, request_id) do
    # The preview validates the request. Its phase mutation is kept out of the
    # journal until the owned process has stopped and the provider effect has
    # reconciled.
    case Rules.apply(state.managed.data, envelope, %{stop_reconciled: true}) do
      {:duplicate, response} ->
        {:reply, {:ok, Map.put(response, :duplicate, true)}, state}

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}

      {:ok, _preview, response} ->
        running? = Map.has_key?(state.running, assignment_id)
        intent = managed_transition_intent(envelope, assignment_id, target, request_id, running?)
        persist_managed_transition_intent(state, assignment, intent, response, running?)
    end
  end

  defp managed_transition_intent(envelope, assignment_id, target, request_id, running?) do
    %{
      request: envelope,
      request_id: request_id,
      assignment_id: assignment_id,
      target: target,
      context: %{stop_reconciled: not running?}
    }
  end

  defp persist_managed_transition_intent(state, assignment, intent, response, running?) do
    data =
      state.managed.data
      |> update_in([:assignments, intent.assignment_id], fn existing ->
        if running? and is_map(existing) do
          Map.merge(existing, %{
            stop_pending: true,
            pending_effect: %{kind: :stop, status: :pending, target: intent.target, request_id: intent.request_id}
          })
        else
          existing
        end
      end)
      |> put_in([:effect_intents, intent.request_id], Map.merge(intent, %{status: :pending, at: DateTime.utc_now()}))
      |> append_managed_event(%{
        operation: :provider_transition_intent,
        request_id: intent.request_id,
        assignment_id: intent.assignment_id,
        target: intent.target,
        stop_pending: running?
      })

    case persist_managed_data(state, data) do
      {:ok, intent_state} -> continue_managed_transition(intent_state, assignment, intent, response, running?)
      {:error, reason} -> {:reply, {:error, :managed_journal_write_failed, %{reason: inspect(reason)}}, state}
    end
  end

  defp continue_managed_transition(state, _assignment, intent, response, true) do
    stopped_state = managed_stop_owned_process(state, intent.assignment_id)

    {:reply,
     {:ok,
      response
      |> Map.put(:pending, true)
      |> Map.put(:stop_pending, true)
      |> Map.put(:request_id, intent.request_id)}, stopped_state}
  end

  defp continue_managed_transition(state, assignment, intent, response, false) do
    execute_managed_transition(state, assignment, intent, response)
  end

  defp managed_process_stopped_for_envelope?(state, envelope) do
    assignment_id = map_value(map_value(envelope, :args) || %{}, :assignment_id)
    not Map.has_key?(state.running, assignment_id)
  end

  defp execute_managed_transition(%State{} = state, assignment, intent, _response) do
    with {:ok, provider_assignment} <- managed_transition_provider_assignment(state, assignment, intent),
         {:ok, reconciled_state} <- managed_apply_provider_transition(state, provider_assignment, intent.target) do
      commit_managed_transition(reconciled_state, intent)
    else
      {:error, failed_state, reason} -> fail_managed_transition(failed_state, intent, reason)
      {:error, reason} -> fail_managed_transition(state, intent, reason)
    end
  end

  defp managed_transition_provider_assignment(state, assignment, %{request: request, assignment_id: assignment_id}) do
    if map_value(request, :operation) in [:revise, "revise"] do
      case Rules.apply(state.managed.data, request, %{stop_reconciled: true}) do
        {:ok, preview, _response} -> {:ok, Map.fetch!(preview.assignments, assignment_id)}
        {:duplicate, _response} -> {:ok, assignment}
        {:error, code, details} -> {:error, {code, details}}
      end
    else
      {:ok, assignment}
    end
  end

  defp commit_managed_transition(state, intent) do
    context =
      Map.put(intent.context, :stop_reconciled, managed_process_stopped_for_envelope?(state, intent.request))

    case Rules.apply(state.managed.data, intent.request, context) do
      {:ok, committed_data, committed_response} ->
        persist_committed_managed_transition(state, intent, committed_data, committed_response)

      {:duplicate, committed_response} ->
        {:reply, {:ok, Map.put(committed_response, :duplicate, true)}, state}

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}
    end
  end

  defp persist_committed_managed_transition(state, intent, committed_data, committed_response) do
    data =
      committed_data
      |> put_in([:effect_intents, intent.request_id, :status], :committed)
      |> put_in([:effect_intents, intent.request_id, :committed_at], DateTime.utc_now())
      |> append_managed_event(%{
        operation: :provider_transition_committed,
        request_id: intent.request_id,
        assignment_id: intent.assignment_id,
        target: intent.target
      })

    case persist_managed_data(state, data) do
      {:ok, final_state} ->
        {:reply, {:ok, committed_response}, final_state}

      {:error, reason} ->
        {:reply, {:error, :managed_journal_write_failed, %{reason: inspect(reason)}}, state}
    end
  end

  defp fail_managed_transition(state, intent, reason) do
    failed_data =
      state.managed.data
      |> update_in([:effect_intents, intent.request_id], fn existing ->
        (existing || %{})
        |> Map.put(:last_error, reason)
        |> Map.put(:last_error_at, DateTime.utc_now())
      end)
      |> append_managed_event(%{
        operation: :provider_transition_failed,
        request_id: intent.request_id,
        assignment_id: intent.assignment_id,
        target: intent.target
      })

    case persist_managed_data(state, failed_data) do
      {:ok, next_state} ->
        {:reply, {:error, reason}, next_state}

      {:error, journal_reason} ->
        {:reply, {:error, :managed_journal_write_failed, %{reason: inspect(journal_reason)}}, state}
    end
  end

  defp apply_managed_control(%State{managed: %{journal: journal, data: data}} = state, envelope, context) do
    case Rules.apply(data, envelope, context) do
      {:ok, next_data, response} ->
        case Journal.append(journal, next_data) do
          :ok ->
            {:reply, {:ok, response}, %{state | managed: %{state.managed | data: next_data}}}

          {:error, reason} ->
            {:reply, {:error, :managed_journal_write_failed, %{reason: inspect(reason)}}, state}
        end

      {:duplicate, response} ->
        {:reply, {:ok, Map.put(response, :duplicate, true)}, state}

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}
    end
  end

  defp handle_managed_review_control(%State{} = state, envelope) do
    case Rules.prepare_review(state.managed.data, envelope) do
      {:duplicate, response} ->
        {:reply, {:ok, Map.put(response, :duplicate, true)}, state}

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}

      {:ok, %{requires_effects: false}} ->
        apply_managed_control(state, envelope, %{})

      {:ok, intent} ->
        begin_managed_review(state, intent)
    end
  end

  defp begin_managed_review(%State{} = state, intent) do
    request = intent.request
    request_id = request.request_id
    existing = get_in(state.managed.data, [:review_intents, request_id])

    cond do
      is_map(existing) and existing[:canonical] != intent.canonical ->
        {:reply, {:error, :request_id_conflict, %{request_id: request_id}}, state}

      is_map(existing) and existing[:status] == :committed ->
        apply_managed_control(state, request, %{})

      true ->
        data =
          state.managed.data
          |> Map.put(
            :review_intents,
            Map.put(state.managed.data[:review_intents] || %{}, request_id, %{
              request_id: request_id,
              canonical: intent.canonical,
              request: request,
              assignment_id: request.args.assignment_id,
              revision: intent.assignment.revision,
              status: :pending,
              at: DateTime.utc_now()
            })
          )
          |> append_managed_event(%{
            operation: :review_intent,
            request_id: request_id,
            assignment_id: request.args.assignment_id,
            revision: intent.assignment.revision,
            phase: :review_pending
          })

        case persist_managed_data(state, data) do
          {:ok, intent_state} ->
            execute_managed_review(intent_state, intent)

          {:error, reason} ->
            {:reply, {:error, :managed_journal_write_failed, %{reason: inspect(reason)}}, state}
        end
    end
  end

  defp execute_managed_review(%State{} = state, intent) do
    case managed_review_effects(state, intent) do
      {:ok, facts} ->
        commit_managed_review(state, intent, facts)

      {:error, code, details} ->
        managed_review_failed(state, intent, code, details)
    end
  end

  defp commit_managed_review(state, intent, facts) do
    facts =
      facts
      |> Map.put(:revision, intent.assignment.revision)
      |> Map.put(:review_request_id, intent.request.request_id)

    with {:ok, reconciled_data, _reconcile_response} <-
           record_managed_reconciliation(state.managed.data, intent.assignment.assignment_id, facts),
         {:ok, reconciled_state} <- persist_managed_data(state, reconciled_data),
         {:ok, next_data, response} <- Rules.apply(reconciled_data, intent.request, facts) do
      complete_and_persist_managed_review(reconciled_state, next_data, intent, response)
    else
      {:duplicate, response} -> {:reply, {:ok, Map.put(response, :duplicate, true)}, state}
      {:error, code, details} -> managed_review_failed(state, intent, code, details)
      {:error, reason} -> managed_review_failed(state, intent, :managed_review_failed, %{reason: inspect(reason)})
    end
  end

  defp complete_and_persist_managed_review(state, data, intent, response) do
    completed_data = complete_managed_review_intent(data, intent.request.request_id)

    case persist_managed_data(state, completed_data) do
      {:ok, final_state} ->
        {:reply, {:ok, response}, final_state}

      {:error, reason} ->
        {:reply, {:error, :managed_journal_write_failed, %{reason: inspect(reason)}}, state}
    end
  end

  defp managed_review_effects(%State{managed: %{effects: module, data: data}} = state, intent)
       when is_atom(module) do
    if managed_review_available?(module) do
      call_managed_review_effect(state, module, data, intent)
    else
      {:error, :managed_review_effects_unavailable, %{}}
    end
  end

  defp managed_review_effects(_state, _intent), do: {:error, :managed_review_effects_unavailable, %{}}

  defp managed_review_available?(module) do
    Code.ensure_loaded?(module) and
      (function_exported?(module, :review, 3) or function_exported?(module, :review, 2))
  end

  defp call_managed_review_effect(state, module, data, intent) do
    result =
      if function_exported?(module, :review, 3) do
        module.review(intent.assignment, intent.request.args, %{
          binding: data[:binding],
          process_stopped: not Map.has_key?(state.running, intent.assignment.assignment_id)
        })
      else
        module.review(intent.assignment, intent.request.args)
      end

    normalize_managed_review_result(result)
  rescue
    error -> {:error, :managed_review_effects_failed, %{reason: Exception.message(error)}}
  catch
    kind, reason -> {:error, :managed_review_effects_failed, %{reason: inspect({kind, reason})}}
  end

  defp normalize_managed_review_result({:ok, facts}) when is_map(facts), do: {:ok, facts}

  defp normalize_managed_review_result({:error, code, details})
       when is_atom(code) and is_map(details),
       do: {:error, code, details}

  defp normalize_managed_review_result({:error, reason}),
    do: {:error, :managed_review_effects_failed, %{reason: inspect(reason)}}

  defp normalize_managed_review_result(_result), do: {:error, :managed_review_effects_failed, %{}}

  defp managed_review_failed(%State{} = state, intent, code, details) do
    request_id = intent.request.request_id

    data =
      state.managed.data
      |> update_in([:review_intents, request_id], fn existing ->
        (existing || %{})
        |> Map.put(:status, :pending)
        |> Map.put(:last_error, code)
        |> Map.put(:last_error_at, DateTime.utc_now())
      end)
      |> append_managed_event(%{
        operation: :review_effect_failed,
        request_id: request_id,
        assignment_id: intent.assignment.assignment_id,
        error: code
      })

    case persist_managed_data(state, data) do
      {:ok, failed_state} -> {:reply, {:error, code, details}, failed_state}
      {:error, reason} -> {:reply, {:error, :managed_journal_write_failed, %{reason: inspect(reason)}}, state}
    end
  end

  defp complete_managed_review_intent(data, request_id) do
    data
    |> update_in([:review_intents, request_id], fn existing ->
      (existing || %{})
      |> Map.put(:status, :committed)
      |> Map.put(:committed_at, DateTime.utc_now())
    end)
    |> append_managed_event(%{operation: :review_committed, request_id: request_id})
  end

  defp append_managed_event(data, event_data) do
    cursor = Map.get(data, :event_cursor, 0) + 1

    event =
      event_data
      |> Map.put(:cursor, cursor)
      |> Map.put(:at, DateTime.utc_now())

    data
    |> Map.put(:event_cursor, cursor)
    |> Map.put(:events, [event | Enum.take(Map.get(data, :events, []), 99)])
  end

  defp persist_managed_data(%State{managed: %{journal: journal}} = state, data) do
    case Journal.append(journal, data) do
      :ok -> {:ok, %{state | managed: %{state.managed | data: data}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    case Map.get(running_entry, :managed_attempt) do
      attempt when is_map(attempt) ->
        handle_managed_agent_down(reason, state, issue_id, running_entry, attempt)

      _ ->
        handle_generic_agent_down(reason, state, issue_id, running_entry, session_id)
    end
  end

  defp handle_generic_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        delay_type: :continuation,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp handle_generic_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp handle_managed_agent_down(reason, %State{} = state, issue_id, running_entry, attempt) do
    assignment = get_in(state.managed.data, [:assignments, issue_id])

    if managed_agent_assignment?(assignment, attempt) do
      complete_managed_agent_down(state, issue_id, assignment, running_entry, attempt, reason)
    else
      state
    end
  end

  defp managed_agent_assignment?(assignment, attempt) when is_map(assignment) do
    managed_attempt_matches?(assignment, attempt) == :ok
  end

  defp managed_agent_assignment?(_assignment, _attempt), do: false

  defp complete_managed_agent_down(state, issue_id, assignment, running_entry, attempt, reason) do
    stop_intent = managed_pending_stop_intent(state.managed.data, issue_id)

    {phase, board_state, pending_effect, stop_pending, blocked_reason} =
      managed_agent_down_transition(
        stop_intent,
        reason,
        assignment[:phase],
        assignment[:stop_pending],
        assignment[:source_authoritative],
        assignment,
        attempt
      )

    previous_usage_total = get_in(assignment, [:usage, :total_tokens]) || 0

    retrying? =
      phase == :ready and managed_retry_allowed?(assignment) and match?({:managed_agent_failed, _}, reason)

    updated =
      assignment
      |> Map.merge(%{phase: phase, board_state: board_state, pending_effect: pending_effect})
      |> maybe_put_managed(
        :retry_count,
        if(retrying?, do: (assignment[:retry_count] || 0) + 1, else: assignment[:retry_count])
      )
      |> maybe_put_managed(:resume_ready, if(retrying?, do: false, else: assignment[:resume_ready]))
      |> Map.put(:usage, %{
        input_tokens: Map.get(running_entry, :codex_input_tokens, 0),
        output_tokens: Map.get(running_entry, :codex_output_tokens, 0),
        total_tokens: Map.get(running_entry, :codex_total_tokens, 0),
        seconds_running: running_seconds(Map.get(running_entry, :started_at), DateTime.utc_now())
      })
      |> maybe_put_managed(:stop_pending, stop_pending)
      |> maybe_put_managed(:blocked_reason, blocked_reason)

    data =
      state.managed.data
      |> put_in([:assignments, issue_id], updated)
      |> update_in([:usage], &managed_finalize_usage(&1, running_entry, previous_usage_total, state.managed.data[:usage_limit_tokens]))
      |> append_managed_event(%{
        operation: :agent_down,
        assignment_id: issue_id,
        attempt_id: attempt.attempt_id,
        phase: phase,
        reason: inspect(reason)
      })

    persist_managed_agent_down(state, data, updated, stop_intent, phase, issue_id)
  end

  defp persist_managed_agent_down(state, data, updated, stop_intent, phase, issue_id) do
    case persist_managed_data(state, data) do
      {:ok, next_state} ->
        finalize_managed_agent_down(next_state, updated, stop_intent, phase, issue_id)

      {:error, error} ->
        Logger.error("Managed agent completion could not be persisted for #{issue_id}: #{inspect(error)}")
        state
    end
  end

  defp finalize_managed_agent_down(state, updated, stop_intent, phase, issue_id) when is_map(stop_intent) do
    if is_map(Map.get(stop_intent, :request)) do
      {:reply, _reply, final_state} = execute_managed_transition(state, updated, stop_intent, %{})
      final_state
    else
      finalize_managed_agent_down(state, updated, nil, phase, issue_id)
    end
  end

  defp finalize_managed_agent_down(state, updated, _stop_intent, phase, _issue_id)
       when phase in [:ready, :review, :waiting, :cancelled] do
    case managed_apply_provider_transition(state, updated, phase) do
      {:ok, provider_state} -> provider_state
      {:error, provider_state, _reason} -> provider_state
    end
  end

  defp finalize_managed_agent_down(state, _updated, _stop_intent, _phase, _issue_id), do: state

  defp managed_agent_down_transition(stop_intent, reason, phase, stop_pending, source_authoritative, assignment, attempt) do
    managed_stop_intent_result(stop_intent, phase, stop_pending, assignment, attempt) ||
      managed_source_stopped_result(phase, stop_pending, source_authoritative, attempt) ||
      managed_guard_stopped_result(reason, phase, stop_pending, source_authoritative, assignment, attempt) ||
      managed_terminal_result(reason, phase, stop_pending, assignment, attempt) ||
      managed_guard_result(reason, phase, assignment, attempt) ||
      managed_failure_result(reason, assignment, attempt) ||
      managed_normal_result(reason, phase, attempt) ||
      managed_unknown_result(reason, attempt)
  end

  defp managed_stop_intent_result(%{request: request, target: target}, phase, true, assignment, attempt)
       when is_map(request) and target in [:ready, :waiting, :cancelled] do
    pending_effect = %{kind: :run, status: :stop_confirmed, target: target, attempt_id: attempt.attempt_id}
    {phase, phase, pending_effect, true, assignment[:blocked_reason]}
  end

  defp managed_stop_intent_result(_stop_intent, _phase, _stop_pending, _assignment, _attempt), do: nil

  defp managed_source_stopped_result(phase, true, true, attempt) do
    {phase, phase, %{kind: :run, status: :source_stopped, attempt_id: attempt.attempt_id}, false, nil}
  end

  defp managed_source_stopped_result(_phase, _stop_pending, _source_authoritative, _attempt), do: nil

  defp managed_guard_stopped_result({:managed_agent_guard_stop, _guard_reason}, phase, true, false, assignment, attempt) do
    {phase, phase, %{kind: :run, status: :stopped, attempt_id: attempt.attempt_id}, true, assignment[:blocked_reason]}
  end

  defp managed_guard_stopped_result(_reason, _phase, _stop_pending, _source_authoritative, _assignment, _attempt), do: nil

  defp managed_terminal_result({:managed_agent_terminal, _report}, phase, _stop_pending, _assignment, attempt)
       when phase in [:review, :accepted] do
    {phase, phase, %{kind: :run, status: :completed, attempt_id: attempt.attempt_id}, false, nil}
  end

  defp managed_terminal_result({:managed_agent_terminal, _report}, phase, true, assignment, attempt)
       when phase in [:waiting, :cancelled] do
    pending_effect = %{kind: :run, status: :report_deferred, attempt_id: attempt.attempt_id}
    {phase, phase, pending_effect, true, assignment[:blocked_reason]}
  end

  defp managed_terminal_result(_reason, _phase, _stop_pending, _assignment, _attempt), do: nil

  defp managed_guard_result({:managed_agent_guard_stop, guard_reason}, phase, assignment, attempt)
       when phase in [:review, :waiting] do
    blocked_reason = if phase == :waiting, do: assignment[:blocked_reason], else: nil

    pending_effect = %{
      kind: :run,
      status: :guard_stopped,
      reason: inspect(guard_reason),
      attempt_id: attempt.attempt_id
    }

    {phase, phase, pending_effect, false, blocked_reason}
  end

  defp managed_guard_result({:managed_agent_guard_stop, guard_reason}, _phase, _assignment, attempt) do
    pending_effect = %{
      kind: :run,
      status: :guard_stopped,
      reason: inspect(guard_reason),
      attempt_id: attempt.attempt_id
    }

    {:waiting, :waiting, pending_effect, true, inspect(guard_reason)}
  end

  defp managed_guard_result(_reason, _phase, _assignment, _attempt), do: nil

  defp managed_failure_result({:managed_agent_failed, failure}, assignment, attempt) do
    if managed_retry_allowed?(assignment) and managed_transient_failure?(failure) do
      pending_effect = %{
        kind: :run,
        status: :retry_pending,
        reason: inspect(failure),
        attempt_id: attempt.attempt_id
      }

      {:ready, :ready, pending_effect, false, nil}
    else
      pending_effect = %{
        kind: :run,
        status: :unknown,
        reason: inspect(failure),
        attempt_id: attempt.attempt_id
      }

      {:waiting, :waiting, pending_effect, true, inspect(failure)}
    end
  end

  defp managed_failure_result(_reason, _assignment, _attempt), do: nil

  defp managed_normal_result(:normal, phase, attempt) when phase in [:review, :waiting, :accepted] do
    {phase, phase, %{kind: :run, status: :completed, attempt_id: attempt.attempt_id}, false, nil}
  end

  defp managed_normal_result(_reason, _phase, _attempt), do: nil

  defp managed_unknown_result(reason, attempt) do
    pending_effect = %{
      kind: :run,
      status: :unknown,
      reason: inspect(reason),
      attempt_id: attempt.attempt_id
    }

    {:waiting, :waiting, pending_effect, true, inspect(reason)}
  end

  defp managed_pending_stop_intent(data, assignment_id) when is_map(data) and is_binary(assignment_id) do
    find_managed_stop_intent(data[:effect_intents], assignment_id)
  end

  defp managed_pending_stop_intent(_data, _assignment_id), do: nil

  defp find_managed_stop_intent(intents, assignment_id) when is_map(intents) do
    Enum.find_value(intents, fn {_request_id, intent} ->
      if managed_stop_intent?(intent, assignment_id), do: intent
    end)
  end

  defp find_managed_stop_intent(_intents, _assignment_id), do: nil

  defp managed_stop_intent?(intent, assignment_id) when is_map(intent) do
    intent[:assignment_id] == assignment_id and
      intent[:status] in [:pending, :effect_reconciled] and is_map(intent[:request]) and
      intent[:target] in [:ready, :waiting, :cancelled]
  end

  defp managed_stop_intent?(_intent, _assignment_id), do: false

  defp managed_retry_allowed?(assignment) when is_map(assignment) do
    retry_count = assignment[:retry_count] || 0
    reserved = assignment[:turns_reserved] || 0
    limit = assignment[:turn_limit] || 20

    is_integer(retry_count) and retry_count < 2 and is_integer(reserved) and
      is_integer(limit) and reserved < min(limit, 20)
  end

  defp managed_retry_allowed?(_assignment), do: false

  defp managed_transient_failure?(failure) do
    text = inspect(failure) |> String.downcase()

    not Enum.any?(
      [
        "invalid",
        "unauthorized",
        "forbidden",
        "configuration",
        "malformed",
        "turn_budget_exhausted",
        "policy"
      ],
      &String.contains?(text, &1)
    )
  end

  defp maybe_put_managed(map, key, nil), do: Map.delete(map, key)
  defp maybe_put_managed(map, key, value), do: Map.put(map, key, value)

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end

  defp maybe_dispatch(%State{managed: managed} = state) when not is_nil(managed), do: state

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Tracker project scope missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from issue tracker: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec recover_managed_usage_inflight_for_test(term()) :: term()
  def recover_managed_usage_inflight_for_test(%State{} = state) do
    recover_managed_usage_inflight(state)
  end

  @doc false
  @spec recover_managed_transitions_for_test(term()) :: term()
  def recover_managed_transitions_for_test(%State{} = state) do
    recover_managed_transitions(state)
  end

  @doc false
  @spec mark_managed_dispatch_failed_for_test(term(), String.t(), map(), term()) :: term()
  def mark_managed_dispatch_failed_for_test(%State{} = state, issue_id, attempt, reason)
      when is_binary(issue_id) and is_map(attempt) do
    managed_mark_dispatch_failed(state, issue_id, attempt, reason)
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        cleanup_issue_workspace(issue, Map.get(state.blocked, issue.id, %{}))
        release_issue_claim(state, issue.id)

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        stop_running_task(pid, ref, state.task_supervisor)

        if cleanup_workspace do
          cleanup_issue_workspace(Map.get(running_entry, :issue, identifier), running_entry)
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(issue_id, false)
        |> schedule_issue_retry(issue_id, next_attempt, %{
          identifier: identifier,
          issue_url: running_entry.issue.url,
          error: "stalled for #{elapsed_ms}ms without codex activity"
        })
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid, _task_supervisor), do: :ok

  defp stop_running_task(pid, ref, task_supervisor) do
    if is_pid(pid) do
      terminate_task(pid, task_supervisor)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    stop_running_task(
      Map.get(running_entry, :pid),
      Map.get(running_entry, :ref),
      state.task_supervisor
    )

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error) do
    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      error: error,
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp dispatch_cycle(%State{managed: nil} = state), do: maybe_dispatch(state)
  defp dispatch_cycle(%State{} = state), do: managed_maybe_dispatch(state)

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1) and
      issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case refresh_issue_for_dispatch(issue) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, _reason} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp refresh_issue_for_dispatch(issue) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issues_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        {:ok, refreshed_issue}

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        {:skip, :missing}

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        {:skip, refreshed_issue}

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp managed_attempt_for_issue(%State{managed: %{data: data}}, issue_id) do
    case get_in(data, [:assignments, issue_id]) do
      %{attempt_id: attempt_id, revision: revision, generation: generation} = assignment
      when is_binary(attempt_id) and is_integer(revision) and is_integer(generation) ->
        %{
          assignment_id: issue_id,
          revision: revision,
          generation: generation,
          attempt_id: attempt_id,
          model: route_value(assignment[:route], :model),
          effort: route_value(assignment[:route], :effort),
          escalation_reason: assignment[:escalation_reason]
        }

      _ ->
        nil
    end
  end

  defp managed_attempt_for_issue(_state, _issue_id), do: nil

  defp managed_checkout_options do
    case Config.settings() do
      {:ok, %{managed: managed}} ->
        values = %{
          node_executable: managed.checkout_node,
          helper_path: managed.checkout_helper_path,
          policy_file: managed.checkout_policy_file
        }

        if Enum.all?(Map.values(values), &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, values}
        else
          {:error, :managed_checkout_configuration_missing}
        end

      {:error, reason} ->
        {:error, {:managed_checkout_configuration_invalid, reason}}
    end
  rescue
    error -> {:error, {:managed_checkout_configuration_invalid, Exception.message(error)}}
  end

  defp managed_run_options(%State{managed: %{data: data}} = _state, %Issue{id: issue_id} = issue) do
    case managed_attempt_for_issue(%State{managed: %{data: data}}, issue_id) do
      %{assignment_id: ^issue_id} = attempt ->
        build_managed_run_options(data, issue, attempt)

      _ ->
        []
    end
  end

  defp managed_run_options(_state, _issue), do: []

  defp build_managed_run_options(data, issue, attempt) do
    owner = self()
    assignment = get_in(data, [:assignments, issue.id])
    checkout_options = managed_checkout_options_or_empty()

    resume_options = managed_resume_options(assignment)
    workspace_preparer = managed_workspace_preparer(issue, assignment, attempt, checkout_options)

    resume_options ++
      [
        managed_attempt: attempt,
        model: attempt[:model],
        effort: attempt[:effort],
        escalation_reason: attempt[:escalation_reason],
        workspace_preparer: workspace_preparer,
        on_session: fn info -> managed_callback_call(owner, {:managed_session, attempt, info}) end,
        before_turn: fn context -> managed_callback_call(owner, {:managed_before_turn, context}) end,
        report_callback: fn payload -> managed_callback_call(owner, {:managed_report, payload}) end
      ]
  end

  defp managed_checkout_options_or_empty do
    case managed_checkout_options() do
      {:ok, options} -> options
      {:error, _reason} -> %{}
    end
  end

  defp managed_resume_options(assignment) when is_map(assignment) do
    if assignment[:resume_ready] == true and is_binary(assignment[:thread_id]) do
      [resume_thread_id: assignment[:thread_id]]
    else
      []
    end
  end

  defp managed_resume_options(_assignment), do: []

  defp managed_workspace_preparer(_issue, _assignment, _attempt, checkout_options)
       when map_size(checkout_options) == 0,
       do: nil

  defp managed_workspace_preparer(issue, assignment, attempt, checkout_options) do
    fn workspace ->
      Checkout.prepare(workspace, issue, assignment, attempt, Map.to_list(checkout_options))
    end
  end

  defp managed_callback_call(owner, message) when is_pid(owner) do
    GenServer.call(owner, message, 15_000)
  catch
    :exit, reason -> {:error, {:managed_orchestrator_unavailable, reason}}
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    run_opts = [attempt: attempt, worker_host: worker_host] ++ managed_run_options(state, issue)

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           AgentRunner.run(issue, recipient, run_opts)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            managed_attempt: managed_attempt_for_issue(state, issue.id),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issues_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue, metadata)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(issue_or_identifier, metadata) when is_map(metadata) do
    case Map.get(metadata, :workspace_path) do
      workspace_path when is_binary(workspace_path) and workspace_path != "" ->
        Workspace.remove_recorded(workspace_path, Map.get(metadata, :worker_host))

      _ ->
        cleanup_issue_workspace(issue_or_identifier, Map.get(metadata, :worker_host))
    end
  end

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_issue_or_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{} = issue ->
            cleanup_issue_workspace(issue)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp initialize_managed(config, %State{} = state, opts) do
    enabled = config.managed.enabled == true or Application.get_env(:symphony_elixir, :managed_mode, false) == true

    if enabled do
      with {:ok, journal, loaded} <- Journal.open(config.managed.journal_path),
           {:ok, data} <- managed_data(loaded, config) do
        effects =
          Keyword.get(
            opts,
            :managed_effects,
            Application.get_env(:symphony_elixir, :managed_effects, SymphonyElixir.Managed.GitHubEffects)
          )

        source_fetcher =
          Keyword.get(
            opts,
            :managed_source_fetcher,
            Application.get_env(:symphony_elixir, :managed_source_fetcher, &Tracker.fetch_issues_by_ids/1)
          )

        {:ok, %{state | managed: %{journal: journal, data: data, effects: effects, source_fetcher: source_fetcher}}}
      end
    else
      {:ok, state}
    end
  end

  defp managed_data(%{} = data, config) when map_size(data) == 0 do
    {:ok, Rules.new(usage_limit_tokens: config.managed.usage_limit_tokens)}
  end

  defp managed_data(%{version: version} = data, config) do
    if version == Rules.version() do
      defaults = Rules.new(usage_limit_tokens: config.managed.usage_limit_tokens)
      merged = Map.merge(defaults, data)
      usage_limit = config.managed.usage_limit_tokens || merged[:usage_limit_tokens]
      {:ok, Map.put(merged, :usage_limit_tokens, usage_limit) |> normalize_managed_usage()}
    else
      {:error, :managed_journal_schema_mismatch}
    end
  end

  defp managed_data(_data, _config), do: {:error, :managed_journal_schema_mismatch}

  defp normalize_managed_usage(%{usage: usage} = data) when is_map(usage) do
    normalized = %{
      baseline_tokens: nonnegative_integer(usage[:baseline_tokens], 0),
      cumulative_tokens: nonnegative_integer(usage[:cumulative_tokens], 0),
      inflight_tokens: nonnegative_integer(usage[:inflight_tokens], 0),
      overshoot_tokens: nonnegative_integer(usage[:overshoot_tokens], 0),
      cap_reached: usage[:cap_reached] == true
    }

    Map.put(data, :usage, normalized)
  end

  defp normalize_managed_usage(data) when is_map(data) do
    Map.put(data, :usage, %{
      baseline_tokens: 0,
      cumulative_tokens: 0,
      inflight_tokens: 0,
      overshoot_tokens: 0,
      cap_reached: false
    })
  end

  defp nonnegative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value, default), do: default

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      case refresh_issue_for_dispatch(issue) do
        {:ok, %Issue{} = refreshed_issue} ->
          {:noreply, do_dispatch_issue(state, refreshed_issue, attempt, metadata[:worker_host])}

        {:skip, :missing} ->
          {:noreply, release_issue_claim(state, issue.id)}

        {:skip, %Issue{} = refreshed_issue} ->
          handle_retry_issue_lookup(refreshed_issue, state, issue.id, attempt, metadata)

        {:error, reason} ->
          {:noreply,
           schedule_issue_retry(
             state,
             issue.id,
             attempt + 1,
             Map.merge(metadata, %{
               identifier: issue.identifier,
               error: "retry dispatch refresh failed: #{inspect(reason)}"
             })
           )}
      end
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  defp snapshot_call(_from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  defp request_refresh_call(_from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
