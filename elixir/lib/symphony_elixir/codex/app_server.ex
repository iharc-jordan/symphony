defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH, Workflow}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @thread_resume_id 4
  @turn_interrupt_id 5
  @config_read_id 6
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @managed_default_model "gpt-5.6-luna"
  @managed_default_effort "xhigh"
  @managed_permissions_profile "symphony_worker"
  @managed_models ["gpt-5.6-luna", "gpt-5.6-terra"]
  @managed_efforts ["xhigh", "max"]
  @report_kinds ["result", "checkpoint", "context_needed"]
  @stop_term_timeout_ms 500
  @stop_kill_timeout_ms 500
  @stop_poll_ms 10
  @scope_identity_timeout_ms 5_000
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          dynamic_tool_binding: map(),
          managed_attempt: map() | nil,
          thread_model: String.t() | nil,
          turn_model: String.t() | nil,
          turn_effort: String.t() | nil,
          thread_default_reasoning_effort: String.t() | nil,
          report_callback: (map() -> term()) | nil,
          permissions_profile: String.t() | nil
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
           permissions_profile: @managed_permissions_profile,
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
    with {:ok, configured_effort} <- configured_effort(opts) do
      managed_route_values(opts, raw_attempt, configured_effort || @managed_default_effort)
    end
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
    callback = Keyword.get(opts, :report_callback, Keyword.get(opts, :report))

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
    %{model: Keyword.get(opts, :model), effort: configured_effort_value(opts), managed: false}
  end

  defp configured_effort(opts) do
    effort = Keyword.get(opts, :effort)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)

    cond do
      not is_nil(effort) and not is_nil(reasoning_effort) and effort != reasoning_effort ->
        {:error, {:route_mismatch, :effort, effort, reasoning_effort}}

      not is_nil(effort) ->
        {:ok, effort}

      true ->
        {:ok, reasoning_effort}
    end
  end

  defp configured_effort_value(opts) do
    case configured_effort(opts) do
      {:ok, effort} -> effort
      {:error, _reason} -> nil
    end
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

  defp permissions_profile(%{permissions_profile: profile}), do: profile
  defp permissions_profile(nil), do: nil

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

  defp maybe_put_permissions(params, nil), do: params

  defp maybe_put_permissions(params, profile) when is_binary(profile) do
    params
    |> Map.delete("sandbox")
    |> Map.put("permissions", profile)
  end

  defp maybe_put_turn_permissions(params, nil), do: params

  defp maybe_put_turn_permissions(params, profile) when is_binary(profile) do
    params
    |> Map.delete("sandboxPolicy")
    |> Map.put("permissions", profile)
  end

  defp route_wire_key(:model), do: "model"
  defp route_wire_key(:effort), do: "effort"

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    dynamic_tool_binding = DynamicTool.bind()

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, managed_config} <- managed_config(opts),
         {:ok, managed_config} <- prepare_managed_config(expanded_workspace, managed_config),
         {:ok, resume_thread_id} <- resume_thread_id(opts),
         :ok <- validate_managed_worker_host(worker_host, managed_config),
         :ok <- validate_managed_runtime(worker_host, managed_config),
         {:ok, port} <-
           start_port(expanded_workspace, worker_host, dynamic_tool_binding, managed_config) do
      metadata = port_metadata(port, worker_host, managed_config, expanded_workspace)
      dynamic_tool_binding = bind_managed_report(dynamic_tool_binding, managed_config)
      wire_route = wire_route(opts, managed_config)

      with :ok <- validate_managed_metadata(metadata, managed_config),
           {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_info} <-
             do_start_session(
               port,
               expanded_workspace,
               session_policies,
               dynamic_tool_binding,
               wire_route,
               resume_thread_id,
               permissions_profile(managed_config)
             ) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_info.thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           dynamic_tool_binding: dynamic_tool_binding,
           managed_attempt: managed_attempt_identity(managed_config),
           thread_model: thread_info.model,
           turn_model: route_value(wire_route, :model),
           turn_effort: route_value(wire_route, :effort),
           thread_default_reasoning_effort: thread_info.default_reasoning_effort,
           report_callback: report_callback(managed_config),
           permissions_profile: permissions_profile(managed_config)
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
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace,
          dynamic_tool_binding: dynamic_tool_binding,
          managed_attempt: managed_attempt,
          turn_model: turn_model,
          turn_effort: turn_effort,
          report_callback: report_callback,
          permissions_profile: permissions_profile
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
           %{route: route, permissions_profile: permissions_profile}
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
            turn_id: turn_id
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
               managed_tool_executor,
               auto_approve_requests
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
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

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
        worker_host: worker_host,
        managed_attempt: managed_attempt,
        thread_model: thread_model,
        turn_model: turn_model,
        turn_effort: turn_effort,
        thread_default_reasoning_effort: thread_default_reasoning_effort,
        permissions_profile: permissions_profile
      }) do
    %{
      thread_id: thread_id,
      workspace: workspace,
      worker_host: worker_host,
      managed_attempt: managed_attempt,
      thread_model: thread_model,
      turn_model: turn_model,
      turn_effort: turn_effort,
      thread_default_reasoning_effort: thread_default_reasoning_effort,
      permissions_profile: permissions_profile,
      metadata: metadata
    }
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, dynamic_tool_binding, managed_config) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [
              ~c"-lc",
              String.to_charlist(local_launch_command(workspace, dynamic_tool_binding, managed_config))
            ],
            cd: String.to_charlist(workspace),
            env: tracker_secret_port_env(dynamic_tool_binding),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding, managed_config)
       when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding, managed_config)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp local_launch_command(workspace, dynamic_tool_binding, managed_config) do
    launch_command = Config.settings!().codex.command

    process_command =
      case managed_config do
        %{permissions_profile: profile} ->
          managed_process_wrapper(
            workspace,
            launch_command <>
              managed_cli_overrides(
                workspace,
                profile,
                Map.get(managed_config, :mcp_server_names, [])
              ),
            managed_config
          )

        nil ->
          "exec #{launch_command}"
      end

    [
      tracker_secret_unset_command(dynamic_tool_binding),
      process_command
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, dynamic_tool_binding, managed_config)
       when is_binary(workspace) do
    launch_command = Config.settings!().codex.command

    launch_command =
      case managed_config do
        %{permissions_profile: profile} ->
          launch_command <>
            managed_cli_overrides(
              workspace,
              profile,
              Map.get(managed_config, :mcp_server_names, [])
            )

        nil ->
          launch_command
      end

    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{launch_command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp managed_process_wrapper(workspace, launch_command, managed_config) do
    unit = systemd_unit_for_managed(workspace, managed_config)
    parent_properties = systemd_parent_properties()

    [
      "exec systemd-run --user --scope --quiet --collect --unit=#{unit}",
      parent_properties,
      "-- #{launch_command}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp managed_cli_overrides(workspace, profile, mcp_server_names) do
    filesystem =
      managed_filesystem_paths(workspace)
      |> Enum.map(&{&1, "deny"})
      |> Kernel.++([
        {workspace, "write"},
        {Path.join(workspace, ".git"), "write"},
        {":workspace_roots", {:table, [{".", "write"}]}}
      ])
      |> toml_inline_table()

    config_overrides = [
      "default_permissions=#{toml_string(profile)}",
      "permissions.#{profile}.extends=\":workspace\"",
      "permissions.#{profile}.filesystem.glob_scan_max_depth=3",
      "permissions.#{profile}.filesystem=#{filesystem}"
    ]

    feature_overrides = [
      "--disable apps",
      "--disable plugins",
      "--disable multi_agent",
      "--disable multi_agent_v2"
    ]

    config_overrides =
      config_overrides ++
        ["agents.enabled=false"] ++
        Enum.map(mcp_server_names, fn name ->
          "mcp_servers.#{toml_key(name)}.enabled=false"
        end)

    (feature_overrides ++ Enum.flat_map(config_overrides, &["-c", shell_escape(&1)]))
    |> Enum.join(" ")
    |> then(&(" " <> &1))
  end

  defp toml_inline_table(entries) when is_list(entries) do
    entries
    |> Enum.map_join(",", fn {key, value} -> "#{toml_string(key)}=#{toml_value(value)}" end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp toml_value({:table, entries}), do: toml_inline_table(entries)
  defp toml_value(value) when is_binary(value), do: toml_string(value)

  defp managed_filesystem_paths(workspace) when is_binary(workspace) do
    settings = Config.settings!()
    managed = Map.get(settings, :managed)

    [
      "~/.codex",
      managed_codex_home(),
      "~/.ssh",
      "~/.config/gh",
      "~/.config/codex-orchestration",
      "~/.local/state/codex-orchestration",
      System.get_env("GH_CONFIG_DIR"),
      Config.local_workspace_root(),
      Workflow.workflow_file_path(),
      managed_path(managed, :control_token_file),
      managed_path(managed, :journal_path),
      managed_path(managed, :checkout_policy_file),
      managed_path(managed, :checkout_helper_path)
    ]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&Path.expand/1)
    |> minimal_denied_paths()
  end

  defp minimal_denied_paths(paths) when is_list(paths) do
    paths
    |> Enum.uniq()
    |> Enum.sort_by(fn path -> {length(Path.split(path)), path} end)
    |> Enum.reduce([], fn path, minimal_paths ->
      if Enum.any?(minimal_paths, &path_covers?(&1, path)) do
        minimal_paths
      else
        [path | minimal_paths]
      end
    end)
    |> Enum.reverse()
  end

  defp path_covers?(ancestor, path) when is_binary(ancestor) and is_binary(path) do
    ancestor_parts = Path.split(ancestor)
    path_parts = Path.split(path)
    Enum.take(path_parts, length(ancestor_parts)) == ancestor_parts
  end

  defp managed_codex_home do
    case System.get_env("CODEX_HOME") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> Path.expand(value)
        end

      _ ->
        nil
    end
  end

  defp prepare_managed_config(_workspace, nil), do: {:ok, nil}

  defp prepare_managed_config(workspace, managed_config) when is_binary(workspace) do
    with {:ok, names} <- managed_mcp_server_names(workspace) do
      {:ok, Map.put(managed_config, :mcp_server_names, names)}
    end
  end

  defp managed_mcp_server_names(workspace) when is_binary(workspace) do
    workspace
    |> managed_config_paths()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn path, {:ok, names} ->
      case mcp_server_names_from_config(path) do
        :absent ->
          {:cont, {:ok, names}}

        {:ok, path_names} ->
          names = Enum.reduce(path_names, names, &MapSet.put(&2, &1))
          {:cont, {:ok, names}}

        {:error, reason} ->
          {:halt, {:error, {:managed_mcp_config_unreadable, path, reason}}}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, names |> MapSet.to_list() |> Enum.sort()}
      error -> error
    end
  end

  defp managed_config_paths(workspace) when is_binary(workspace) do
    codex_home = System.get_env("CODEX_HOME")

    user_config =
      if is_binary(codex_home) and String.trim(codex_home) != "" do
        Path.join(Path.expand(codex_home), "config.toml")
      else
        Path.expand("~/.codex/config.toml")
      end

    project_configs =
      workspace
      |> Path.expand()
      |> ancestor_paths()
      |> Enum.map(&Path.join([&1, ".codex", "config.toml"]))

    [user_config | project_configs] |> Enum.uniq()
  end

  defp ancestor_paths(path) when is_binary(path) do
    path = Path.expand(path)
    do_ancestor_paths(path, [])
  end

  defp do_ancestor_paths(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      Enum.reverse([path | acc])
    else
      do_ancestor_paths(parent, [path | acc])
    end
  end

  defp mcp_server_names_from_config(path) when is_binary(path) do
    case File.stat(path) do
      {:error, reason} when reason in [:enoent, :enotdir] ->
        :absent

      {:error, reason} ->
        {:error, reason}

      {:ok, %{type: :regular}} ->
        case File.read(path) do
          {:ok, contents} -> parse_mcp_config(contents)
          {:error, reason} -> {:error, reason}
        end

      {:ok, _file_info} ->
        {:error, :not_a_regular_file}
    end
  end

  defp parse_mcp_config(contents) when is_binary(contents) do
    with {:ok, config} when is_map(config) <- TomlElixir.decode(contents),
         servers when is_map(servers) <- Map.get(config, "mcp_servers", %{}) do
      {:ok, servers |> Map.keys() |> Enum.sort()}
    else
      _ -> {:error, {:invalid_mcp_config, :invalid_toml}}
    end
  end

  defp managed_path(managed, key) when is_map(managed), do: Map.get(managed, key)
  defp managed_path(_managed, _key), do: nil

  defp systemd_unit_for_managed(workspace, %{attempt: attempt, unit_nonce: unit_nonce})
       when is_binary(workspace) and is_binary(unit_nonce) do
    unit_identity = [
      workspace,
      attempt.assignment_id,
      to_string(attempt.revision),
      Integer.to_string(attempt.generation),
      attempt.attempt_id,
      unit_nonce
    ]

    digest =
      unit_identity
      |> Enum.join("\0")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "symphony-managed-#{digest}.scope"
  end

  defp systemd_unit_for_managed(workspace, _managed_config) when is_binary(workspace) do
    systemd_unit_for_workspace(workspace)
  end

  defp systemd_unit_for_workspace(workspace) when is_binary(workspace) do
    digest = :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "symphony-managed-#{digest}.scope"
  end

  defp systemd_parent_properties do
    case systemd_parent_service_unit() do
      nil -> ""
      unit -> "--property=BindsTo=#{shell_escape(unit)} --property=PartOf=#{shell_escape(unit)}"
    end
  end

  defp systemd_parent_service_unit do
    configured = System.get_env("SYMPHONY_SYSTEMD_PARENT_UNIT")

    if is_binary(configured) and String.trim(configured) != "" do
      String.trim(configured)
    else
      case File.read("/proc/self/cgroup") do
        {:ok, cgroup} ->
          cgroup
          |> String.trim()
          |> String.split("/", trim: true)
          |> Enum.filter(&String.ends_with?(&1, ".service"))
          |> Enum.reject(&String.starts_with?(&1, "user@"))
          |> List.last()

        _ ->
          nil
      end
    end
  end

  defp toml_key(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Za-z0-9_-]+$/), do: value, else: toml_string(value)
  end

  defp toml_string(value) when is_binary(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    case dynamic_tool_binding.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host, managed_config, workspace) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> process_port_metadata(os_pid, worker_host, managed_config, workspace)
        _ -> managed_scope_metadata(worker_host, managed_config, workspace)
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp process_port_metadata(os_pid, nil, managed_config, workspace) when is_map(managed_config) do
    unit = systemd_unit_for_managed(workspace, managed_config)

    metadata = %{
      codex_app_server_pid: to_string(os_pid),
      systemd_unit: unit,
      systemd_unit_identity: managed_unit_identity(managed_config),
      parent_systemd_service: systemd_parent_service_unit()
    }

    add_scope_identity(metadata, process_identity(os_pid), await_systemd_scope_identity(unit, os_pid))
  end

  defp process_port_metadata(os_pid, _worker_host, _managed_config, _workspace) do
    %{codex_app_server_pid: to_string(os_pid), containment: :remote_unverified}
  end

  defp add_scope_identity(metadata, {:ok, identity}, {:ok, scope_identity}) do
    metadata
    |> add_process_identity({:ok, identity})
    |> Map.merge(%{containment: :systemd_scope, systemd_invocation_id: scope_identity.invocation_id})
  end

  defp add_scope_identity(metadata, process_result, scope_result) do
    metadata
    |> add_process_identity(process_result)
    |> Map.merge(%{
      containment: :unverified,
      containment_error: {:process_or_scope_identity_unavailable, process_result, scope_result}
    })
  end

  defp add_process_identity(metadata, {:ok, identity}) do
    Map.merge(metadata, %{
      codex_app_server_pgid: to_string(identity.pgid),
      codex_app_server_start_time: identity.start_time,
      codex_app_server_boot_id: identity.boot_id,
      codex_process_identity: identity
    })
  end

  defp add_process_identity(metadata, _result), do: metadata

  defp managed_scope_metadata(nil, managed_config, workspace) when is_map(managed_config) do
    unit = systemd_unit_for_managed(workspace, managed_config)

    %{
      containment: :unverified,
      containment_error: :os_pid_unavailable,
      systemd_unit: unit,
      systemd_unit_identity: managed_unit_identity(managed_config),
      parent_systemd_service: systemd_parent_service_unit()
    }
  end

  defp managed_scope_metadata(_worker_host, _managed_config, _workspace), do: %{}
  defp validate_managed_metadata(_metadata, nil), do: :ok

  defp validate_managed_metadata(
         %{containment: :systemd_scope, systemd_invocation_id: invocation_id},
         _managed_config
       )
       when is_binary(invocation_id) and invocation_id != "",
       do: :ok

  defp validate_managed_metadata(%{containment: containment} = metadata, _managed_config),
    do: {:error, {:managed_containment_unverified, containment, Map.get(metadata, :containment_error)}}

  defp validate_managed_metadata(_metadata, _managed_config), do: {:error, :managed_containment_unverified}

  defp managed_unit_identity(%{attempt: attempt} = managed_config) do
    %{
      assignment_id: attempt.assignment_id,
      revision: attempt.revision,
      generation: attempt.generation,
      attempt_id: attempt.attempt_id,
      unit_nonce: Map.get(managed_config, :unit_nonce)
    }
  end

  defp managed_unit_identity(_managed_config), do: nil

  defp managed_unit_nonce do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end

  defp validate_managed_worker_host(nil, _managed_config), do: :ok
  defp validate_managed_worker_host(_worker_host, nil), do: :ok

  defp validate_managed_worker_host(worker_host, _managed_config) when is_binary(worker_host) do
    {:error, {:managed_remote_worker_unsupported, worker_host}}
  end

  defp validate_managed_runtime(_worker_host, nil), do: :ok

  defp validate_managed_runtime(nil, _managed_config) do
    if System.find_executable("systemd-run") do
      :ok
    else
      {:error, :managed_containment_unavailable}
    end
  end

  defp validate_managed_runtime(_worker_host, _managed_config), do: :ok

  defp process_identity(pid) when is_integer(pid) and pid > 0 do
    with {:ok, boot_id} <- File.read("/proc/sys/kernel/random/boot_id"),
         {:ok, stat} <- read_proc_stat(pid),
         true <- stat.pgid > 0 do
      {:ok,
       %{
         pid: pid,
         pgid: stat.pgid,
         start_time: stat.start_time,
         boot_id: String.trim(boot_id)
       }}
    else
      false -> {:error, :invalid_process_group}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_identity(_pid), do: {:error, :invalid_process_id}

  defp await_systemd_scope_identity(unit, pid) when is_binary(unit) and is_integer(pid) do
    deadline = System.monotonic_time(:millisecond) + @scope_identity_timeout_ms
    await_systemd_scope_identity_until(unit, pid, deadline)
  end

  defp await_systemd_scope_identity_until(unit, pid, deadline) do
    expired = System.monotonic_time(:millisecond) >= deadline

    case systemd_scope_snapshot(unit) do
      {:ok, %{invocation_id: invocation_id} = identity}
      when is_binary(invocation_id) and invocation_id != "" ->
        {:ok, identity}

      _ when expired ->
        {:error, :scope_invocation_unavailable}

      _ ->
        Process.sleep(@stop_poll_ms)
        await_systemd_scope_identity_until(unit, pid, deadline)
    end
  end

  defp systemd_scope_identity(unit) when is_binary(unit) do
    case systemd_scope_snapshot(unit) do
      {:ok, %{active_state: state, invocation_id: invocation_id} = identity}
      when state in [:active, :activating, :deactivating] and is_binary(invocation_id) and
             invocation_id != "" ->
        {:ok, identity}

      {:ok, %{active_state: state}} when state in [:inactive, :failed] ->
        {:error, :not_found}

      {:ok, _identity} ->
        {:error, :scope_invocation_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp systemd_scope_snapshot(unit) when is_binary(unit) do
    case System.cmd(
           "systemctl",
           [
             "--user",
             "show",
             unit,
             "--property=ActiveState",
             "--property=InvocationID",
             "--no-pager"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        properties =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, &put_systemd_property/2)

        with {:ok, active_state} <- systemd_active_state(Map.get(properties, "ActiveState")) do
          {:ok,
           %{
             active_state: active_state,
             invocation_id: Map.get(properties, "InvocationID", "")
           }}
        end

      {output, _status} when is_binary(output) ->
        if systemd_unit_not_found?(output), do: {:error, :not_found}, else: {:error, :systemd_query_failed}

      _ ->
        {:error, :systemd_query_failed}
    end
  rescue
    _error -> {:error, :systemd_query_failed}
  end

  defp put_systemd_property(line, properties) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> Map.put(properties, key, value)
      _ -> properties
    end
  end

  defp systemd_active_state("active"), do: {:ok, :active}
  defp systemd_active_state("activating"), do: {:ok, :activating}
  defp systemd_active_state("deactivating"), do: {:ok, :deactivating}
  defp systemd_active_state("failed"), do: {:ok, :failed}
  defp systemd_active_state("inactive"), do: {:ok, :inactive}
  defp systemd_active_state(_state), do: {:error, :invalid_systemd_state}

  defp systemd_unit_not_found?(output) when is_binary(output) do
    String.match?(output, ~r/(unit .* (not loaded|not found)|could not be found)/i)
  end

  defp read_proc_stat(pid) do
    with {:ok, contents} <- File.read("/proc/#{pid}/stat") do
      parse_proc_stat(contents)
    end
  end

  defp parse_proc_stat(contents) do
    case Regex.run(~r/^\s*\d+\s+\((.*)\)\s+(.*)$/s, contents, capture: :all_but_first) do
      [_comm, fields] -> parse_proc_fields(String.split(fields))
      _ -> {:error, :invalid_process_stat}
    end
  end

  defp parse_proc_fields(values) do
    with {:ok, pgid} <- parse_proc_integer(Enum.at(values, 2)),
         {:ok, start_time} <- parse_proc_integer(Enum.at(values, 19)),
         state when is_binary(state) <- Enum.at(values, 0) do
      {:ok, %{pgid: pgid, start_time: start_time, state: state}}
    else
      _ -> {:error, :invalid_process_stat}
    end
  end

  defp parse_proc_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :invalid_process_stat}
    end
  end

  defp parse_proc_integer(_value), do: {:error, :invalid_process_stat}

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
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(
         port,
         workspace,
         session_policies,
         dynamic_tool_binding,
         wire_route,
         resume_thread_id,
         permissions_profile
       ) do
    case send_initialize(port) do
      :ok ->
        with :ok <- validate_managed_mcp_configuration(port, workspace, permissions_profile) do
          start_thread_or_resume(
            port,
            workspace,
            session_policies,
            dynamic_tool_binding,
            wire_route,
            resume_thread_id,
            permissions_profile
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_managed_mcp_configuration(_port, _workspace, nil), do: :ok

  defp validate_managed_mcp_configuration(port, workspace, _permissions_profile)
       when is_port(port) and is_binary(workspace) do
    send_message(port, %{
      "method" => "config/read",
      "id" => @config_read_id,
      "params" => %{"cwd" => workspace, "includeLayers" => true}
    })

    case await_response(port, @config_read_id) do
      {:ok, %{"config" => %{"mcp_servers" => mcp_servers}}} when is_map(mcp_servers) ->
        reject_enabled_mcp_servers(mcp_servers)

      {:ok, _response} ->
        {:error, {:managed_mcp_configuration_unavailable, :invalid_response}}

      {:error, reason} ->
        {:error, {:managed_mcp_configuration_read_failed, reason}}
    end
  end

  defp reject_enabled_mcp_servers(mcp_servers) do
    case Enum.find(mcp_servers, &mcp_server_enabled?/1) do
      nil -> :ok
      {name, _config} -> {:error, {:managed_mcp_server_enabled, name}}
    end
  end

  defp mcp_server_enabled?({_name, config}), do: Map.get(config, "enabled", true) != false

  defp start_thread_or_resume(
         port,
         workspace,
         session_policies,
         dynamic_tool_binding,
         wire_route,
         resume_thread_id,
         permissions_profile
       )
       when is_binary(resume_thread_id) do
    resume_thread(
      port,
      workspace,
      session_policies,
      dynamic_tool_binding,
      wire_route,
      resume_thread_id,
      permissions_profile
    )
  end

  defp start_thread_or_resume(
         port,
         workspace,
         session_policies,
         dynamic_tool_binding,
         wire_route,
         nil,
         permissions_profile
       ) do
    start_thread(
      port,
      workspace,
      session_policies,
      dynamic_tool_binding,
      wire_route,
      permissions_profile
    )
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tool_binding,
         wire_route,
         permissions_profile
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
        |> maybe_put_route(wire_route, :model)
        |> maybe_put_permissions(permissions_profile)
    })

    case await_response(port, @thread_start_id) do
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
         resume_thread_id,
         permissions_profile
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
        |> maybe_put_route(wire_route, :model)
        |> maybe_put_permissions(permissions_profile)
    })

    case await_response(port, @thread_resume_id) do
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
         %{route: wire_route, permissions_profile: permissions_profile}
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
      |> maybe_put_turn_permissions(permissions_profile)

    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => params |> maybe_put_route(wire_route, :model) |> maybe_put_route(wire_route, :effort)
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
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
          tool_executor,
          auto_approve_requests
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

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

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

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
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
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
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
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      {:stop, reason} ->
        emit_message(
          on_message,
          :turn_ended_with_error,
          %{payload: payload, raw: payload_string, reason: reason},
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
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
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
        {:stop, {:orchestration_report_failed, reason}}

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

        event =
          case result do
            %{"success" => true} -> :tool_call_completed
            _ when is_nil(tool_name) -> :unsupported_tool_call
            _ -> :tool_call_failed
          end

        emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

        :approved
    end
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
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
    deadline = System.monotonic_time(:millisecond) + min(Config.settings!().codex.read_timeout_ms, 10_000)
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

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
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
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
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

    close_result = close_port(port)

    case {stop_result, close_result} do
      {:ok, :ok} ->
        :ok

      {{:error, reason}, _} ->
        {:error, {:process_stop_unconfirmed, reason}}
    end
  end

  defp managed_process_metadata?(%{systemd_unit: unit}) when is_binary(unit) and unit != "", do: true
  defp managed_process_metadata?(_metadata), do: false

  defp stop_recorded_metadata(%{
         containment: :systemd_scope,
         systemd_unit: unit,
         systemd_invocation_id: invocation_id,
         codex_process_identity: identity
       })
       when is_binary(unit) and is_map(identity) and is_binary(invocation_id) and invocation_id != "" do
    stop_systemd_scope(unit, identity, invocation_id)
  end

  defp stop_recorded_metadata(%{systemd_unit: unit, codex_process_identity: identity})
       when is_binary(unit) and is_map(identity) do
    stop_systemd_scope_without_invocation(unit, identity)
  end

  defp stop_recorded_metadata(%{containment: :systemd_scope}),
    do: {:error, :missing_systemd_invocation_identity}

  defp stop_recorded_metadata(%{containment: :unverified, systemd_unit: unit} = metadata)
       when is_binary(unit) and unit != "",
       do: stop_unverified_systemd_scope(unit, metadata)

  defp stop_recorded_metadata(%{containment: :unverified} = metadata),
    do: {:error, {:process_stop_unconfirmed, Map.get(metadata, :containment_error)}}

  defp stop_recorded_metadata(%{containment: :remote_unverified}),
    do: {:error, :remote_process_stop_unverified}

  defp stop_recorded_metadata(_metadata), do: {:error, :recorded_process_stop_unsupported}

  defp stop_unverified_systemd_scope(unit, metadata) do
    case systemd_scope_identity(unit) do
      {:error, :not_found} ->
        :ok

      {:ok, _identity} ->
        {:error, {:process_stop_unconfirmed, Map.get(metadata, :containment_error)}}

      {:error, reason} ->
        {:error, {:process_stop_unconfirmed, reason}}
    end
  end

  defp stop_systemd_scope(unit, %{pid: pid} = identity, invocation_id)
       when is_binary(unit) and is_integer(pid) and is_binary(invocation_id) do
    case process_identity(pid) do
      {:ok, ^identity} ->
        stop_verified_systemd_scope(unit, identity, invocation_id)

      {:ok, current_identity} ->
        {:error, {:process_identity_changed, identity, current_identity}}

      {:error, reason} when reason in [:enoent, :esrch] ->
        stop_verified_systemd_scope(unit, identity, invocation_id)

      {:error, reason} ->
        {:error, {:process_identity_unreadable, identity, reason}}
    end
  end

  defp stop_systemd_scope(_unit, _identity, _invocation_id), do: {:error, :invalid_process_identity}

  defp stop_verified_systemd_scope(unit, identity, invocation_id) do
    case verify_systemd_scope_identity(unit, invocation_id) do
      :ok -> terminate_systemd_scope(unit, identity, invocation_id)
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_systemd_scope_without_invocation(unit, %{pid: pid} = identity)
       when is_binary(unit) and is_integer(pid) do
    case process_identity(pid) do
      {:ok, ^identity} ->
        with :ok <- verify_process_in_systemd_unit(pid, unit) do
          terminate_systemd_scope_without_invocation(unit, identity)
        end

      {:ok, current_identity} ->
        {:error, {:process_identity_changed, identity, current_identity}}

      {:error, reason} when reason in [:enoent, :esrch] ->
        case systemd_scope_snapshot(unit) do
          {:error, :not_found} -> :ok
          {:ok, %{active_state: state}} when state in [:inactive, :failed] -> :ok
          other -> {:error, {:process_stop_unconfirmed, {:process_gone_scope_active, unit, other}}}
        end

      {:error, reason} ->
        {:error, {:process_identity_unreadable, identity, reason}}
    end
  end

  defp stop_systemd_scope_without_invocation(_unit, _identity),
    do: {:error, :invalid_process_identity}

  defp verify_process_in_systemd_unit(pid, unit) do
    case File.read("/proc/#{pid}/cgroup") do
      {:ok, cgroup} ->
        path = cgroup |> String.trim() |> String.split(":", parts: 3) |> List.last()

        if is_binary(path) and (path == "/#{unit}" or String.ends_with?(path, "/#{unit}")) do
          :ok
        else
          {:error, {:process_unit_mismatch, pid, unit, path}}
        end

      {:error, reason} ->
        {:error, {:process_cgroup_unreadable, pid, unit, reason}}
    end
  end

  defp terminate_systemd_scope_without_invocation(unit, identity) do
    await_exit = fn timeout -> await_systemd_scope_exit_without_invocation(unit, identity, timeout) end
    terminate_scope(unit, await_exit, fn -> :ok end)
  end

  defp terminate_scope(unit, await_exit, verify_identity) do
    case signal_systemd_scope(unit, "TERM") do
      :ok -> finish_scope_termination(unit, await_exit, verify_identity)
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:scope_signal_failed, "TERM", unit, reason}}
    end
  end

  defp finish_scope_termination(unit, await_exit, verify_identity) do
    case await_exit.(@stop_term_timeout_ms) do
      :ok ->
        :ok

      {:error, active} ->
        with :ok <- verify_identity.() do
          kill_remaining_scope(unit, await_exit, active)
        end
    end
  end

  defp kill_remaining_scope(unit, await_exit, active) do
    case signal_systemd_scope(unit, "KILL") do
      :ok -> confirm_scope_killed(unit, await_exit.(@stop_kill_timeout_ms), active)
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:scope_signal_failed, "KILL", unit, reason}}
    end
  end

  defp confirm_scope_killed(_unit, :ok, _active), do: :ok

  defp confirm_scope_killed(unit, {:error, remaining}, active),
    do: {:error, %{unit: unit, active: active, remaining: remaining}}

  defp await_systemd_scope_exit_without_invocation(unit, identity, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_systemd_scope_exit_without_invocation_until(unit, identity, deadline)
  end

  defp await_systemd_scope_exit_without_invocation_until(unit, identity, deadline) do
    scope_result = systemd_scope_snapshot(unit)
    process_state = process_identity(identity.pid)

    cond do
      systemd_scope_exited?(scope_result, process_state) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, %{scope: scope_result, process_state: process_state}}

      true ->
        Process.sleep(@stop_poll_ms)
        await_systemd_scope_exit_without_invocation_until(unit, identity, deadline)
    end
  end

  defp verify_systemd_scope_identity(unit, invocation_id) do
    case systemd_scope_identity(unit) do
      {:ok, %{invocation_id: ^invocation_id}} ->
        :ok

      {:ok, %{invocation_id: current_invocation_id}} ->
        {:error, {:systemd_invocation_changed, invocation_id, current_invocation_id}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:systemd_invocation_unverified, invocation_id, reason}}
    end
  end

  defp terminate_systemd_scope(unit, identity, invocation_id) do
    await_exit = fn timeout -> await_systemd_scope_exit(unit, identity, invocation_id, timeout) end
    verify_identity = fn -> verify_systemd_scope_identity(unit, invocation_id) end
    terminate_scope(unit, await_exit, verify_identity)
  end

  defp signal_systemd_scope(unit, signal) when is_binary(unit) do
    case System.cmd("systemctl", ["--user", "kill", "--kill-who=all", "--signal=#{signal}", unit], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        if systemd_unit_not_found?(output) do
          {:error, :not_found}
        else
          {:error, {status, String.trim(output)}}
        end
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  end

  defp await_systemd_scope_exit(unit, identity, invocation_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_systemd_scope_exit_until(unit, identity, invocation_id, deadline)
  end

  defp await_systemd_scope_exit_until(unit, identity, invocation_id, deadline) do
    scope_result = systemd_scope_snapshot(unit)
    process_state = process_identity(identity.pid)

    cond do
      scope_result in [{:error, :not_found}] and process_gone?(process_state) ->
        :ok

      systemd_scope_exited?(scope_result, process_state) ->
        :ok

      systemd_scope_identity_changed?(scope_result, invocation_id) ->
        {:error, %{reason: :systemd_invocation_changed, scope: scope_result}}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, %{scope: scope_result, process_state: process_state}}

      true ->
        Process.sleep(@stop_poll_ms)
        await_systemd_scope_exit_until(unit, identity, invocation_id, deadline)
    end
  end

  defp systemd_scope_exited?({:error, :not_found}, process_state), do: process_gone?(process_state)

  defp systemd_scope_exited?({:ok, %{active_state: state}}, process_state)
       when state in [:inactive, :failed],
       do: process_gone?(process_state)

  defp systemd_scope_exited?(_scope_result, _process_state), do: false

  defp process_gone?({:error, reason}) when reason in [:enoent, :esrch], do: true
  defp process_gone?(_process_state), do: false

  defp systemd_scope_identity_changed?({:ok, %{invocation_id: current_invocation_id}}, invocation_id)
       when is_binary(current_invocation_id) and current_invocation_id != "" and
              current_invocation_id != invocation_id,
       do: true

  defp systemd_scope_identity_changed?(_scope_result, _invocation_id), do: false

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

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil, nil, nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

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
