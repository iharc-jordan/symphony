defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, WindowsWorkerHost, Workspace}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @thread_resume_id 4
  @turn_interrupt_id 5
  @max_stream_log_bytes 1_000
  @managed_default_model "gpt-5.6-luna"
  @managed_default_effort "xhigh"
  @managed_models ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"]
  @managed_efforts ["xhigh", "max"]
  @managed_developer_instructions """
  You are a Symphony managed worker. The current managed assignment and its latest revision are your work authority. Work only within that assignment and its owned checkout and resources. Ignore inherited scrum-master or delegation guidance: do not create, delegate, or accept other work. Report checkpoints, context needs, and the final result through orchestration_report; stop acting after a terminal report.
  """
  @report_kinds ["result", "checkpoint", "context_needed"]
  @stop_read_timeout_ms 10_000
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          dynamic_tool_binding: map(),
          managed_attempt: map() | nil,
          thread_model: String.t() | nil,
          turn_model: String.t() | nil,
          turn_effort: String.t() | nil,
          thread_default_reasoning_effort: String.t() | nil,
          report_callback: (map() -> term()) | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      result =
        try do
          run_turn(session, prompt, issue, opts)
        catch
          kind, reason -> {:error, {:session_exception, kind, reason}}
        end

      combine_stop_result(result, stop_session(session))
    end
  end

  defp managed_config(opts) do
    if Keyword.has_key?(opts, :managed_attempt) do
      raw_attempt = Keyword.get(opts, :managed_attempt)

      with {:ok, attempt} <- normalize_managed_attempt(raw_attempt),
           {:ok, route} <- managed_route(opts, raw_attempt),
           {:ok, report_callback} <- normalize_report_callback(opts) do
        {:ok,
         %{
           attempt: attempt,
           route: route,
           report_callback: report_callback,
           unit_nonce: managed_unit_nonce()
         }}
      end
    else
      {:ok, nil}
    end
  end

  defp normalize_managed_attempt(attempt) when is_map(attempt) do
    with {:ok, assignment_id} <- required_binary(attempt, :assignment_id),
         {:ok, revision} <- required_revision(attempt, :revision),
         {:ok, generation} <- required_non_negative_integer(attempt, :generation),
         {:ok, attempt_id} <- required_binary(attempt, :attempt_id) do
      {:ok,
       %{
         assignment_id: assignment_id,
         revision: revision,
         generation: generation,
         attempt_id: attempt_id
       }}
    end
  end

  defp normalize_managed_attempt(_attempt), do: {:error, :invalid_managed_attempt}

  defp managed_route(opts, raw_attempt) do
    managed_route_values(opts, raw_attempt, Keyword.get(opts, :effort) || @managed_default_effort)
  end

  defp managed_route_values(opts, raw_attempt, effort) do
    model = Keyword.get(opts, :model, @managed_default_model)
    attempt_model = optional_map_value(raw_attempt, :model)
    attempt_effort = optional_map_value(raw_attempt, :effort)
    explicit_reason = Keyword.get(opts, :escalation_reason)
    attempt_reason = optional_map_value(raw_attempt, :escalation_reason)

    with :ok <- validate_managed_model(model),
         :ok <- validate_managed_effort(effort),
         :ok <-
           validate_route_metadata(
             attempt_model,
             model,
             attempt_effort,
             effort,
             attempt_reason,
             explicit_reason
           ),
         {:ok, escalation_reason} <-
           resolve_escalation_reason(model, effort, explicit_reason || attempt_reason) do
      {:ok,
       %{
         model: model,
         effort: effort,
         escalation_reason: escalation_reason,
         managed: true
       }}
    end
  end

  defp validate_managed_model(model) when is_binary(model) and model in @managed_models, do: :ok
  defp validate_managed_model(model), do: {:error, {:managed_model_not_allowed, model, @managed_models}}

  defp validate_managed_effort(effort) when is_binary(effort) and effort in @managed_efforts, do: :ok
  defp validate_managed_effort(effort), do: {:error, {:managed_effort_not_allowed, effort, @managed_efforts}}

  defp validate_route_metadata(attempt_model, model, attempt_effort, effort, attempt_reason, explicit_reason) do
    cond do
      not is_nil(attempt_model) and attempt_model != model ->
        {:error, {:managed_route_mismatch, :model, attempt_model, model}}

      not is_nil(attempt_effort) and attempt_effort != effort ->
        {:error, {:managed_route_mismatch, :effort, attempt_effort, effort}}

      not is_nil(explicit_reason) and not is_nil(attempt_reason) and explicit_reason != attempt_reason ->
        {:error, {:managed_route_mismatch, :escalation_reason, attempt_reason, explicit_reason}}

      true ->
        :ok
    end
  end

  defp resolve_escalation_reason(@managed_default_model, @managed_default_effort, _reason),
    do: {:ok, nil}

  defp resolve_escalation_reason(_model, _effort, reason)
       when is_binary(reason) do
    if String.trim(reason) == "", do: {:error, :managed_escalation_reason_required}, else: {:ok, reason}
  end

  defp resolve_escalation_reason(_model, _effort, _reason),
    do: {:error, :managed_escalation_reason_required}

  defp normalize_report_callback(opts) do
    callback = Keyword.get(opts, :report_callback)

    cond do
      is_nil(callback) -> {:ok, nil}
      is_function(callback, 1) -> {:ok, callback}
      true -> {:error, :invalid_report_callback}
    end
  end

  defp resume_thread_id(opts) do
    case Keyword.get(opts, :resume_thread_id) do
      nil -> {:ok, nil}
      thread_id when is_binary(thread_id) and byte_size(thread_id) > 0 -> {:ok, thread_id}
      thread_id -> {:error, {:invalid_resume_thread_id, thread_id}}
    end
  end

  defp wire_route(_opts, %{route: route}), do: route

  defp wire_route(opts, nil) do
    %{model: Keyword.get(opts, :model), effort: Keyword.get(opts, :effort), managed: false}
  end

  defp required_binary(map, key) do
    case optional_map_value(map, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_managed_attempt_field, key}}
    end
  end

  defp required_revision(map, key) do
    case optional_map_value(map, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_managed_attempt_field, key}}
    end
  end

  defp required_non_negative_integer(map, key) do
    case optional_map_value(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_managed_attempt_field, key}}
    end
  end

  defp optional_map_value(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp managed_attempt_identity(%{attempt: attempt}), do: attempt
  defp managed_attempt_identity(nil), do: nil

  defp report_callback(%{report_callback: callback}), do: callback
  defp report_callback(nil), do: nil

  defp route_value(route, key), do: Map.get(route, key)

  defp bind_managed_report(binding, nil), do: binding

  defp bind_managed_report(binding, %{attempt: _attempt}) do
    Map.update!(binding, :tool_specs, &(&1 ++ [orchestration_report_tool_spec()]))
  end

  defp orchestration_report_tool_spec do
    %{
      "name" => "orchestration_report",
      "description" => "Report a result, checkpoint, or context-needed event to the Symphony orchestrator.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "kind" => %{
            "type" => "string",
            "enum" => @report_kinds
          },
          "report_id" => %{"type" => "string"},
          "summary" => %{"type" => "string"},
          "evidence" => %{"type" => "array", "items" => true}
        },
        "required" => ["kind", "report_id", "summary", "evidence"],
        "additionalProperties" => false
      }
    }
  end

  defp managed_tool_executor(tool_executor, nil, _report_callback, _thread_id, _turn_id),
    do: tool_executor

  defp managed_tool_executor(tool_executor, attempt, report_callback, thread_id, turn_id) do
    fn tool, arguments ->
      case tool do
        "orchestration_report" ->
          arguments
          |> execute_orchestration_report(report_callback, attempt, thread_id, turn_id)
          |> tag_managed_report_result(thread_id, turn_id)

        _ ->
          tool_executor.(tool, arguments)
      end
    end
  end

  defp tag_managed_report_result({:error, {:orchestration_report, reason}}, thread_id, turn_id),
    do: {:error, {:orchestration_report, reason, thread_id, turn_id}}

  defp tag_managed_report_result({:terminal, result, report}, thread_id, turn_id),
    do: {:terminal, result, report, thread_id, turn_id}

  defp tag_managed_report_result(result, _thread_id, _turn_id), do: result

  defp execute_orchestration_report(arguments, callback, attempt, thread_id, turn_id)
       when is_map(arguments) do
    with {:ok, report} <- normalize_report(arguments),
         {:ok, callback} <- report_callback_available(callback),
         :ok <- invoke_report_callback(callback, Map.merge(report, %{attempt: attempt, thread_id: thread_id, turn_id: turn_id})) do
      result = %{
        "success" => true,
        "output" => "orchestration report accepted",
        "contentItems" => dynamic_tool_content_items("orchestration report accepted")
      }

      if report.kind in ["result", "context_needed"] do
        {:terminal, result, report}
      else
        result
      end
    else
      {:error, reason} -> {:error, {:orchestration_report, reason}}
    end
  end

  defp execute_orchestration_report(_arguments, _callback, _attempt, _thread_id, _turn_id),
    do: {:error, {:orchestration_report, :invalid_orchestration_report}}

  defp normalize_report(arguments) do
    kind = Map.get(arguments, "kind")
    report_id = Map.get(arguments, "report_id")
    summary = Map.get(arguments, "summary")
    evidence = Map.get(arguments, "evidence")

    if kind in @report_kinds and is_binary(report_id) and byte_size(report_id) > 0 and
         is_binary(summary) and is_list(evidence) do
      {:ok,
       %{
         kind: kind,
         report_id: report_id,
         summary: summary,
         evidence: evidence
       }}
    else
      {:error, :invalid_orchestration_report}
    end
  end

  defp report_callback_available(callback) when is_function(callback, 1), do: {:ok, callback}
  defp report_callback_available(_callback), do: {:error, :report_callback_not_configured}

  defp invoke_report_callback(callback, payload) do
    case callback.(payload) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_report_callback_result, other}}
    end
  end

  defp maybe_put_route(params, route, key) do
    case Map.get(route, key) do
      value when is_binary(value) -> Map.put(params, route_wire_key(key), value)
      _ -> params
    end
  end

  defp route_wire_key(:model), do: "model"
  defp route_wire_key(:effort), do: "effort"

  defp maybe_put_managed_developer_instructions(params, %{managed: true}),
    do: Map.put(params, "developerInstructions", String.trim(@managed_developer_instructions))

  defp maybe_put_managed_developer_instructions(params, _wire_route), do: params

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    dynamic_tool_binding = DynamicTool.bind()

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace),
         {:ok, managed_config} <- managed_config(opts),
         {:ok, resume_thread_id} <- resume_thread_id(opts),
         :ok <- validate_managed_runtime(managed_config),
         {:ok, port, metadata} <-
           start_port(expanded_workspace, dynamic_tool_binding, managed_config) do
      dynamic_tool_binding = bind_managed_report(dynamic_tool_binding, managed_config)
      wire_route = wire_route(opts, managed_config)

      with :ok <- validate_managed_metadata(metadata, managed_config),
           {:ok, session_policies} <- session_policies(expanded_workspace),
           {:ok, thread_info} <-
             do_start_session(
               port,
               expanded_workspace,
               session_policies,
               dynamic_tool_binding,
               wire_route,
               resume_thread_id
             ) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_info.thread_id,
           workspace: expanded_workspace,
           dynamic_tool_binding: dynamic_tool_binding,
           managed_attempt: managed_attempt_identity(managed_config),
           thread_model: thread_info.model,
           turn_model: route_value(wire_route, :model),
           turn_effort: route_value(wire_route, :effort),
           thread_default_reasoning_effort: thread_info.default_reasoning_effort,
           report_callback: report_callback(managed_config)
         }}
      else
        {:error, reason} ->
          stop_failed_session(port, metadata, reason)
      end
    end
  end

  defp stop_failed_session(port, metadata, reason) do
    case stop_port(port, metadata) do
      :ok -> {:error, reason}
      {:error, stop_reason} -> {:error, {:session_start_stop_failed, reason, stop_reason, metadata}}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace,
          dynamic_tool_binding: dynamic_tool_binding,
          managed_attempt: managed_attempt,
          turn_model: turn_model,
          turn_effort: turn_effort,
          report_callback: report_callback
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, dynamic_tool_binding, issue: issue)
      end)

    route = %{model: turn_model, effort: turn_effort}

    case start_turn(
           port,
           thread_id,
           prompt,
           issue,
           workspace,
           approval_policy,
           turn_sandbox_policy,
           route
         ) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id,
            model: turn_model,
            effort: turn_effort
          },
          metadata
        )

        managed_tool_executor =
          managed_tool_executor(
            tool_executor,
            managed_attempt,
            report_callback,
            thread_id,
            turn_id
          )

        case await_turn_completion(
               port,
               on_message,
               managed_tool_executor
             ) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            {reason, interruption_drained?} = normalize_turn_error(reason)

            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            # Ask the protocol endpoint to stop before the Windows Job Object
            # is closed. The bounded drain preserves the existing ten-second
            # shutdown window; only then can owned-job termination occur. A
            # terminal managed report drains in its request handler so the
            # same completed turn is never interrupted and drained twice.
            maybe_interrupt_and_drain_turn(
              port,
              on_message,
              metadata,
              thread_id,
              turn_id,
              interruption_drained?
            )

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok | {:error, term()}
  def stop_session(%{port: port, metadata: metadata}) when is_port(port) do
    stop_port(port, metadata)
  end

  @spec stop_recorded_process(map()) :: :ok | {:error, term()}
  def stop_recorded_process(metadata) when is_map(metadata) do
    stop_recorded_metadata(metadata)
  end

  def stop_recorded_process(_metadata), do: {:error, :invalid_recorded_process_metadata}

  @doc """
  Returns the stable session details that a host may persist before the first turn.

  The process handle itself is intentionally omitted; `metadata` contains the
  operating-system process identity when the local port exposes one.
  """
  @spec session_info(session()) :: map()
  def session_info(%{
        metadata: metadata,
        thread_id: thread_id,
        workspace: workspace,
        managed_attempt: managed_attempt,
        thread_model: thread_model,
        turn_model: turn_model,
        turn_effort: turn_effort,
        thread_default_reasoning_effort: thread_default_reasoning_effort
      }) do
    %{
      thread_id: thread_id,
      workspace: workspace,
      managed_attempt: managed_attempt,
      thread_model: thread_model,
      turn_model: turn_model,
      turn_effort: turn_effort,
      thread_default_reasoning_effort: thread_default_reasoning_effort,
      metadata: metadata
    }
  end

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    case Workspace.validate_owned_workspace(workspace) do
      {:ok, canonical_workspace} -> {:ok, canonical_workspace}
      {:error, reason} -> {:error, {:invalid_workspace_cwd, reason}}
    end
  end

  defp start_port(workspace, dynamic_tool_binding, managed_config) do
    with {:ok, executable, arguments} <- local_launch(workspace, dynamic_tool_binding, managed_config) do
      WindowsWorkerHost.start(
        workspace,
        executable,
        arguments,
        managed_attempt_identity(managed_config),
        tracker_secret_port_env(dynamic_tool_binding)
      )
    end
  end

  defp local_launch(workspace, dynamic_tool_binding, managed_config) do
    launcher = Config.settings!().codex.launcher
    _ = {workspace, dynamic_tool_binding}

    with true <- is_binary(launcher) and File.regular?(launcher),
         command_processor when is_binary(command_processor) <-
           System.get_env("ComSpec") || System.get_env("COMSPEC"),
         true <- File.regular?(command_processor) do
      codex_arguments = if is_map(managed_config), do: ["app-server" | managed_cli_overrides()], else: ["app-server"]
      payload = "\"\"" <> launcher <> "\" " <> Enum.join(codex_arguments, " ") <> "\""
      {:ok, command_processor, ["/d", "/s", "/c", payload]}
    else
      _ -> {:error, :codex_launcher_unavailable}
    end
  end

  # Symphony owns delegation. All ordinary host tools and configured permission
  # policies remain available to the assigned worker.
  @doc false
  @spec managed_cli_overrides() :: [String.t()]
  def managed_cli_overrides do
    ["-c", "features.multi_agent=false", "-c", "features.multi_agent_v2=false"]
  end

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp validate_managed_metadata(_metadata, nil), do: :ok

  defp validate_managed_metadata(
         %{containment: :windows_job, job_name: job_name, child_pid: pid, child_creation_time: creation_time},
         _managed_config
       )
       when is_binary(job_name) and is_integer(pid) and pid > 0 and is_integer(creation_time) and creation_time > 0,
       do: :ok

  defp validate_managed_metadata(%{containment: containment} = metadata, _managed_config),
    do: {:error, {:managed_containment_unverified, containment, Map.get(metadata, :containment_error)}}

  defp managed_unit_nonce do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end

  defp validate_managed_runtime(nil), do: :ok

  defp validate_managed_runtime(_managed_config) do
    if WindowsWorkerHost.helper_available?() do
      :ok
    else
      {:error, :managed_containment_unavailable}
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => application_version()
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id, "initialize") do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp application_version do
    case Application.spec(:symphony_elixir, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp session_policies(workspace) do
    Config.codex_runtime_settings(workspace)
  end

  defp do_start_session(
         port,
         workspace,
         session_policies,
         dynamic_tool_binding,
         wire_route,
         resume_thread_id
       ) do
    with :ok <- send_initialize(port) do
      start_thread_or_resume(
        port,
        workspace,
        session_policies,
        dynamic_tool_binding,
        wire_route,
        resume_thread_id
      )
    end
  end

  defp start_thread_or_resume(
         port,
         workspace,
         session_policies,
         dynamic_tool_binding,
         wire_route,
         resume_thread_id
       )
       when is_binary(resume_thread_id) do
    resume_thread(
      port,
      workspace,
      session_policies,
      dynamic_tool_binding,
      wire_route,
      resume_thread_id
    )
  end

  defp start_thread_or_resume(
         port,
         workspace,
         session_policies,
         dynamic_tool_binding,
         wire_route,
         nil
       ) do
    start_thread(
      port,
      workspace,
      session_policies,
      dynamic_tool_binding,
      wire_route
    )
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tool_binding,
         wire_route
       ) do
    params = %{
      "approvalPolicy" => approval_policy,
      "sandbox" => thread_sandbox,
      "cwd" => workspace,
      "dynamicTools" => dynamic_tool_binding.tool_specs
    }

    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" =>
        params
        |> maybe_put_managed_developer_instructions(wire_route)
        |> maybe_put_route(wire_route, :model)
    })

    case await_response(port, @thread_start_id, "thread/start") do
      {:ok, response} -> thread_response_info(response, wire_route)
      other -> other
    end
  end

  defp resume_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tool_binding,
         wire_route,
         resume_thread_id
       ) do
    params = %{
      "threadId" => resume_thread_id,
      "approvalPolicy" => approval_policy,
      "sandbox" => thread_sandbox,
      "cwd" => workspace,
      "dynamicTools" => dynamic_tool_binding.tool_specs
    }

    send_message(port, %{
      "method" => "thread/resume",
      "id" => @thread_resume_id,
      "params" =>
        params
        |> maybe_put_managed_developer_instructions(wire_route)
        |> maybe_put_route(wire_route, :model)
    })

    case await_response(port, @thread_resume_id, "thread/resume") do
      {:ok, response} ->
        with {:ok, thread_info} <- thread_response_info(response, wire_route),
             :ok <- validate_resumed_thread_id(thread_info.thread_id, resume_thread_id) do
          {:ok, thread_info}
        end

      other ->
        other
    end
  end

  defp thread_response_info(response, wire_route) when is_map(response) do
    thread_payload = Map.get(response, "thread")

    with %{"id" => thread_id} <- thread_payload,
         {:ok, model} <- response_model(response, wire_route),
         {:ok, default_reasoning_effort} <- response_reasoning_effort(response) do
      {:ok,
       %{
         thread_id: thread_id,
         model: model,
         default_reasoning_effort: default_reasoning_effort
       }}
    else
      nil -> {:error, {:invalid_thread_payload, thread_payload}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_thread_payload, thread_payload}}
    end
  end

  defp thread_response_info(response, _wire_route),
    do: {:error, {:invalid_thread_payload, response}}

  defp response_model(response, %{model: expected_model, managed: true}) when is_binary(expected_model) do
    case Map.get(response, "model") do
      ^expected_model -> {:ok, expected_model}
      nil -> {:error, {:managed_model_missing, expected_model}}
      actual_model -> {:error, {:managed_model_mismatch, expected_model, actual_model}}
    end
  end

  defp response_model(response, _wire_route), do: {:ok, Map.get(response, "model")}

  defp response_reasoning_effort(response) do
    case Map.fetch(response, "reasoningEffort") do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_thread_default_reasoning_effort, value}}
      :error -> {:ok, nil}
    end
  end

  defp validate_resumed_thread_id(actual_thread_id, expected_thread_id)
       when actual_thread_id == expected_thread_id,
       do: :ok

  defp validate_resumed_thread_id(actual_thread_id, expected_thread_id),
    do: {:error, {:resume_thread_mismatch, expected_thread_id, actual_thread_id}}

  defp start_turn(
         port,
         thread_id,
         prompt,
         issue,
         workspace,
         approval_policy,
         turn_sandbox_policy,
         wire_route
       ) do
    params =
      %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }

    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => params |> maybe_put_route(wire_route, :model) |> maybe_put_route(wire_route, :effort)
    })

    case await_response(port, @turn_start_id, "turn/start") do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}

      {:symphony_stop, reason} ->
        {:error, {:stop_requested, reason}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        handle_completed_turn(on_message, payload, payload_string, port)

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/failed"} = payload} ->
        details = Map.get(payload, "params", %{})
        emit_turn_event(on_message, :turn_failed, payload, payload_string, port, details)
        {:error, {:turn_failed, details}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor)
    end
  end

  defp handle_completed_turn(on_message, payload, payload_string, port) do
    case completed_turn_status(payload) do
      :completed ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:failed, details} ->
        emit_turn_event(on_message, :turn_failed, payload, payload_string, port, details)
        {:error, {:turn_failed, details}}

      {:interrupted, details} ->
        emit_turn_event(on_message, :turn_interrupted, payload, payload_string, port, details)
        {:error, {:turn_interrupted, details}}
    end
  end

  defp completed_turn_status(payload) do
    turn = get_in(payload, ["params", "turn"]) || get_in(payload, ["turn"])

    case is_map(turn) && Map.get(turn, "status") do
      "failed" -> {:failed, get_in(payload, ["params"]) || turn}
      "interrupted" -> {:interrupted, get_in(payload, ["params"]) || turn}
      _ -> :completed
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      {:stop, reason} ->
        {public_reason, _interruption_drained?} = normalize_turn_error(reason)

        emit_message(
          on_message,
          :turn_ended_with_error,
          %{payload: payload, raw: payload_string, reason: public_reason},
          metadata
        )

        {:error, reason}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor)
        end
    end
  end

  # The host applies its configured approval policy. Any remaining request
  # requires an actual decision, even if command approvals are set to never.
  defp maybe_handle_approval_request(
         _port,
         method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor
       )
       when method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"],
       do: :approval_required

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    case tool_name |> tool_executor.(arguments) do
      {:terminal, result, report, report_thread_id, report_turn_id} ->
        result = normalize_dynamic_tool_result(result)
        send_message(port, %{"id" => id, "result" => result})
        interrupt_turn(port, report_thread_id, report_turn_id)

        emit_message(
          on_message,
          :tool_call_completed,
          %{payload: payload, raw: payload_string, report: report},
          metadata
        )

        drain_interrupted_turn(port, on_message, metadata, report_thread_id, report_turn_id)
        {:stop, {:orchestration_report_terminal, report}}

      {:error, {:orchestration_report, :invalid_orchestration_report, _report_thread_id, _report_turn_id}} ->
        result =
          normalize_dynamic_tool_result({:error, "Use kind, report_id, summary, and an evidence array; execution identity is attached by the runtime."})

        send_message(port, %{"id" => id, "result" => result})
        emit_message(on_message, :tool_call_failed, %{payload: payload, raw: payload_string}, metadata)
        :approved

      {:error, {:orchestration_report, reason, report_thread_id, report_turn_id}} ->
        result = normalize_dynamic_tool_result({:error, reason})
        send_message(port, %{"id" => id, "result" => result})
        interrupt_turn(port, report_thread_id, report_turn_id)

        emit_message(
          on_message,
          :tool_call_failed,
          %{payload: payload, raw: payload_string, reason: reason},
          metadata
        )

        drain_interrupted_turn(port, on_message, metadata, report_thread_id, report_turn_id)
        {:stop, {:orchestration_report_failed, reason, :interruption_drained}}

      {:error, {:orchestration_report, reason}} ->
        result = normalize_dynamic_tool_result({:error, reason})
        send_message(port, %{"id" => id, "result" => result})
        emit_message(on_message, :tool_call_failed, %{payload: payload, raw: payload_string, reason: reason}, metadata)
        {:stop, {:orchestration_report_failed, reason}}

      {:error, reason} ->
        result = normalize_dynamic_tool_result({:error, reason})
        send_message(port, %{"id" => id, "result" => result})
        emit_message(on_message, :tool_call_failed, %{payload: payload, raw: payload_string}, metadata)
        :approved

      tool_result ->
        result = normalize_dynamic_tool_result(tool_result)

        send_message(port, %{
          "id" => id,
          "result" => result
        })

        event = dynamic_tool_event(result, tool_name)

        emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

        :approved
    end
  end

  defp maybe_handle_approval_request(
         _port,
         "item/tool/requestUserInput",
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor
       ),
       do: :input_required

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor
       ) do
    :unhandled
  end

  defp normalize_turn_error({:orchestration_report_terminal, _report} = reason),
    do: {reason, true}

  defp normalize_turn_error({:orchestration_report_failed, reason, :interruption_drained}),
    do: {{:orchestration_report_failed, reason}, true}

  defp normalize_turn_error(reason), do: {reason, false}

  defp maybe_interrupt_and_drain_turn(_port, _on_message, _metadata, _thread_id, _turn_id, true), do: :ok

  defp maybe_interrupt_and_drain_turn(port, on_message, metadata, thread_id, turn_id, false) do
    interrupt_turn(port, thread_id, turn_id)

    if :erlang.port_info(port) != :undefined do
      drain_interrupted_turn(port, on_message, metadata, thread_id, turn_id)
    end
  end

  defp interrupt_turn(port, thread_id, turn_id)
       when is_binary(thread_id) and is_binary(turn_id) do
    send_message(port, %{
      "method" => "turn/interrupt",
      "id" => @turn_interrupt_id,
      "params" => %{"threadId" => thread_id, "turnId" => turn_id}
    })

    :ok
  end

  defp interrupt_turn(_port, _thread_id, _turn_id), do: :ok

  # A report ends authorization to act, but its final usage can arrive after the
  # tool response. Drain the interrupted turn without executing further tools.
  defp drain_interrupted_turn(port, on_message, metadata, thread_id, turn_id) do
    deadline = System.monotonic_time(:millisecond) + @stop_read_timeout_ms
    drain_interrupted_turn(port, on_message, metadata, {thread_id, turn_id}, deadline, "")
  end

  defp drain_interrupted_turn(port, on_message, metadata, identity, deadline, pending) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      emit_message(on_message, :final_usage_incomplete, %{reason: :interrupt_drain_timeout}, metadata)
    else
      receive_interrupted_turn(port, on_message, metadata, identity, deadline, pending, remaining)
    end
  end

  defp receive_interrupted_turn(port, on_message, metadata, identity, deadline, pending, remaining) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        raw = pending <> to_string(chunk)

        case drain_turn_message(port, on_message, metadata, identity, raw) do
          :complete -> emit_message(on_message, :final_usage_complete, %{}, metadata)
          :continue -> drain_interrupted_turn(port, on_message, metadata, identity, deadline, "")
        end

      {^port, {:data, {:noeol, chunk}}} ->
        drain_interrupted_turn(port, on_message, metadata, identity, deadline, pending <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        emit_message(on_message, :final_usage_incomplete, %{reason: {:port_exit, status}}, metadata)
    after
      remaining ->
        emit_message(on_message, :final_usage_incomplete, %{reason: :interrupt_drain_timeout}, metadata)
    end
  end

  defp drain_turn_message(port, on_message, metadata, {thread_id, turn_id}, raw) do
    case Jason.decode(raw) do
      {:ok, %{"id" => id, "method" => _method}} ->
        send_message(port, %{"id" => id, "error" => %{"code" => -32_000, "message" => "Worker report ended this turn"}})
        :continue

      {:ok, %{"method" => method} = payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: raw}, metadata)

        if method == "turn/completed" and get_in(payload, ["params", "threadId"]) == thread_id and
             get_in(payload, ["params", "turn", "id"]) == turn_id do
          :complete
        else
          :continue
        end

      _ ->
        :continue
    end
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp await_response(port, request_id, method) do
    started_at = System.monotonic_time(:millisecond)
    timeout_ms = Config.settings!().codex.read_timeout_ms

    request = %{
      id: request_id,
      method: method,
      started_at: started_at,
      deadline: started_at + timeout_ms,
      timeout_ms: timeout_ms
    }

    with_timeout_response(port, request, "")
  end

  defp with_timeout_response(port, request, pending_line) do
    remaining = request.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      response_timeout(request)
    else
      receive do
        {^port, {:data, {:eol, chunk}}} ->
          complete_line = pending_line <> to_string(chunk)
          handle_response(port, request, complete_line)

        {^port, {:data, {:noeol, chunk}}} ->
          with_timeout_response(port, request, pending_line <> to_string(chunk))

        {^port, {:exit_status, status}} ->
          {:error, {:port_exit, status}}
      after
        remaining -> response_timeout(request)
      end
    end
  end

  defp response_timeout(request) do
    {:error,
     {:response_timeout,
      %{
        method: request.method,
        stage: if(request.method == "initialize", do: :initialization, else: :request),
        elapsed_ms: max(System.monotonic_time(:millisecond) - request.started_at, 0),
        timeout_ms: request.timeout_ms
      }}}
  end

  defp handle_response(port, request, data) do
    request_id = request.id
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port, metadata) when is_port(port) do
    stop_result =
      if managed_process_metadata?(metadata) do
        stop_recorded_metadata(metadata)
      else
        :ok
      end

    case stop_result do
      :ok ->
        close_port(port)
        :ok

      {:error, reason} ->
        # Do not close a port when the recorded identity no longer verifies:
        # closing its helper would kill whichever job currently owns that port.
        {:error, {:process_stop_unconfirmed, reason}}
    end
  end

  defp managed_process_metadata?(%{containment: :windows_job, job_name: job_name})
       when is_binary(job_name) and job_name != "",
       do: true

  defp managed_process_metadata?(_metadata), do: false

  defp stop_recorded_metadata(
         %{
           containment: :windows_job,
           job_name: job_name,
           child_pid: pid,
           child_creation_time: creation_time
         } = metadata
       )
       when is_binary(job_name) and is_integer(pid) and is_integer(creation_time) do
    WindowsWorkerHost.stop_recorded(metadata)
  end

  defp stop_recorded_metadata(_metadata), do: {:error, :recorded_process_stop_unsupported}

  defp close_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp combine_stop_result(result, :ok), do: result

  defp combine_stop_result({:error, operation_reason}, {:error, stop_reason}) do
    {:error, {:session_stop_failed, stop_reason, operation_reason}}
  end

  defp combine_stop_result(_result, {:error, stop_reason}) do
    {:error, {:session_stop_failed, stop_reason}}
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(_port, payload), do: maybe_set_usage(%{}, payload)

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp dynamic_tool_event(%{"success" => true}, _tool_name), do: :tool_call_completed
  defp dynamic_tool_event(_result, nil), do: :unsupported_tool_call
  defp dynamic_tool_event(_result, _tool_name), do: :tool_call_failed

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
