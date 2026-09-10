defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.

  Managed callers receive structured process exits so the orchestrator can
  distinguish an intentional terminal or guard stop from an execution failure.
  The managed exit shapes are:

    * {:managed_agent_terminal, report} for an accepted terminal report;
    * {:managed_agent_guard_stop, reason} for a callback or exhausted-budget stop;
    * {:managed_agent_failed, reason} for an execution failure.

  Generic callers retain the historical RuntimeError behavior.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")

        if managed_attempt?(opts) do
          exit(managed_exit_reason(reason))
        else
          raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
        end
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        try do
          with :ok <- invoke_workspace_preparer(workspace, opts),
               :ok <-
                 send_worker_runtime_info(
                   codex_update_recipient,
                   issue,
                   worker_host,
                   workspace,
                   Keyword.get(opts, :managed_attempt)
                 ),
               :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue, managed_attempt) do
    fn message ->
      send_codex_update(recipient, issue, message, managed_attempt)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message, managed_attempt)
       when is_binary(issue_id) and is_pid(recipient) do
    update = maybe_scope_update(message, managed_attempt)
    send(recipient, {:codex_worker_update, issue_id, update})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message, _managed_attempt), do: :ok

  defp maybe_scope_update(message, managed_attempt) when is_map(managed_attempt) do
    Map.put(message, :attempt, managed_attempt)
  end

  defp maybe_scope_update(message, _managed_attempt), do: message

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace, managed_attempt)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }
       |> maybe_scope_runtime_info(managed_attempt)}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _managed_attempt), do: :ok

  defp invoke_workspace_preparer(workspace, opts) when is_binary(workspace) do
    preparer = Keyword.get(opts, :workspace_preparer)

    cond do
      is_function(preparer, 1) ->
        normalize_workspace_preparer_result(preparer.(workspace))

      managed_attempt?(opts) and is_nil(preparer) ->
        {:error, :missing_workspace_preparer}

      is_nil(preparer) ->
        :ok

      true ->
        {:error, :invalid_workspace_preparer}
    end
  rescue
    error -> {:error, {:workspace_preparer, {:callback_exception, Exception.message(error)}}}
  end

  defp normalize_workspace_preparer_result(:ok), do: :ok

  defp normalize_workspace_preparer_result({:error, reason}),
    do: {:error, {:workspace_preparer, reason}}

  defp normalize_workspace_preparer_result(other),
    do: {:error, {:workspace_preparer, {:invalid_callback_result, other}}}

  defp maybe_scope_runtime_info(runtime_info, managed_attempt) when is_map(managed_attempt),
    do: Map.put(runtime_info, :attempt, managed_attempt)

  defp maybe_scope_runtime_info(runtime_info, _managed_attempt), do: runtime_info

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    remaining_turns = Keyword.get(opts, :remaining_turns, max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)
    on_session = Keyword.get(opts, :on_session, &default_callback/1)
    before_turn = Keyword.get(opts, :before_turn, &default_callback/1)
    app_server_opts = app_server_opts(opts, worker_host)

    runner_context = %{
      codex_update_recipient: codex_update_recipient,
      issue_state_fetcher: issue_state_fetcher,
      before_turn: before_turn
    }

    case validate_turn_allowance(max_turns, remaining_turns) do
      {:ok, 0} ->
        {:error, :turn_budget_exhausted}

      {:ok, turn_limit} ->
        case AppServer.start_session(workspace, app_server_opts) do
          {:ok, session} ->
            result =
              try do
                case invoke_on_session(on_session, AppServer.session_info(session), issue) do
                  :ok ->
                    do_run_codex_turns(
                      session,
                      workspace,
                      issue,
                      opts,
                      runner_context,
                      1,
                      turn_limit
                    )

                  {:error, reason} ->
                    {:error, reason}
                end
              catch
                kind, reason -> {:error, {:session_exception, kind, reason}}
              end

            combine_session_stop(result, AppServer.stop_session(session))

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, opts, runner_context, turn_number, max_turns) do
    %{
      codex_update_recipient: codex_update_recipient,
      issue_state_fetcher: issue_state_fetcher,
      before_turn: before_turn
    } = runner_context

    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with :ok <-
           invoke_before_turn(
             before_turn,
             before_turn_context(app_session, workspace, issue, turn_number, max_turns)
           ),
         {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message:
               codex_message_handler(
                 codex_update_recipient,
                 issue,
                 app_session.managed_attempt
               )
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      continue_after_turn(
        app_session,
        workspace,
        issue,
        opts,
        runner_context,
        turn_number,
        max_turns,
        issue_state_fetcher
      )
    end
  end

  defp continue_after_turn(
         app_session,
         workspace,
         issue,
         opts,
         runner_context,
         turn_number,
         max_turns,
         issue_state_fetcher
       ) do
    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_codex_turns(
          app_session,
          workspace,
          refreshed_issue,
          opts,
          runner_context,
          turn_number + 1,
          max_turns
        )

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
        exhausted_turn_result(opts)

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exhausted_turn_result(opts) do
    if managed_attempt?(opts), do: {:error, :turn_budget_exhausted}, else: :ok
  end

  defp validate_turn_allowance(max_turns, remaining_turns)
       when is_integer(max_turns) and max_turns >= 0 and
              is_integer(remaining_turns) and remaining_turns >= 0 do
    {:ok, min(max_turns, remaining_turns)}
  end

  defp validate_turn_allowance(max_turns, _remaining_turns)
       when not is_integer(max_turns) or max_turns < 0,
       do: {:error, {:invalid_turn_allowance, :max_turns, max_turns}}

  defp validate_turn_allowance(_max_turns, remaining_turns),
    do: {:error, {:invalid_turn_allowance, :remaining_turns, remaining_turns}}

  defp managed_attempt?(opts), do: Keyword.has_key?(opts, :managed_attempt)

  defp managed_exit_reason({:orchestration_report_terminal, report}),
    do: {:managed_agent_terminal, report}

  defp managed_exit_reason({callback, :stopped, reason}) when callback in [:on_session, :before_turn],
    do: {:managed_agent_guard_stop, {callback, reason}}

  defp managed_exit_reason({callback, reason}) when callback in [:on_session, :before_turn],
    do: {:managed_agent_guard_stop, {callback, reason}}

  defp managed_exit_reason(:turn_budget_exhausted), do: {:managed_agent_guard_stop, :turn_budget_exhausted}
  defp managed_exit_reason(reason), do: {:managed_agent_failed, reason}

  defp combine_session_stop(result, :ok), do: result

  defp combine_session_stop({:error, operation_reason}, {:error, stop_reason}) do
    {:error, {:session_stop_failed, stop_reason, operation_reason}}
  end

  defp combine_session_stop(_result, {:error, stop_reason}) do
    {:error, {:session_stop_failed, stop_reason}}
  end

  defp app_server_opts(opts, worker_host) do
    opts
    |> Keyword.take([
      :managed_attempt,
      :model,
      :effort,
      :reasoning_effort,
      :escalation_reason,
      :resume_thread_id,
      :report_callback,
      :report
    ])
    |> Keyword.put(:worker_host, worker_host)
  end

  defp before_turn_context(session, workspace, issue, turn_number, max_turns) do
    %{
      attempt: session.managed_attempt,
      turn: turn_number,
      remaining_turns: max(max_turns - turn_number + 1, 0),
      thread_id: session.thread_id,
      thread_model: session.thread_model,
      turn_model: session.turn_model,
      turn_effort: session.turn_effort,
      thread_default_reasoning_effort: session.thread_default_reasoning_effort,
      issue: issue,
      workspace: workspace
    }
  end

  defp invoke_on_session(callback, session_info, _issue) when is_function(callback, 1) do
    normalize_callback_result(callback.(session_info), :on_session)
  rescue
    error -> {:error, {:on_session, {:callback_exception, Exception.message(error)}}}
  end

  defp invoke_on_session(_callback, _session_info, _issue), do: {:error, :invalid_on_session_callback}

  defp invoke_before_turn(callback, context) when is_function(callback, 1) do
    normalize_callback_result(callback.(context), :before_turn)
  rescue
    error -> {:error, {:before_turn, {:callback_exception, Exception.message(error)}}}
  end

  defp invoke_before_turn(_callback, _context), do: {:error, :invalid_before_turn_callback}

  defp normalize_callback_result(:ok, _callback_name), do: :ok
  defp normalize_callback_result(:allow, _callback_name), do: :ok
  defp normalize_callback_result({:ok, _value}, _callback_name), do: :ok
  defp normalize_callback_result({:stop, reason}, callback_name), do: {:error, {callback_name, :stopped, reason}}
  defp normalize_callback_result({:error, reason}, callback_name), do: {:error, {callback_name, reason}}

  defp normalize_callback_result(other, callback_name),
    do: {:error, {callback_name, :invalid_callback_result, other}}

  defp default_callback(_value), do: :ok

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
