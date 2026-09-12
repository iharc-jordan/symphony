defmodule SymphonyElixir.RuntimeConfig do
  @moduledoc """
  Applies the absolute Windows paths resolved by the installed launcher before
  any Symphony supervisor starts.

  Path ownership and installation layout are resolved by the plugin lifecycle.
  This module deliberately validates and consumes that contract without
  independently deriving `%LOCALAPPDATA%` paths.
  """

  alias SymphonyElixir.LogFile

  @managed_env "SYMPHONY_MANAGED"
  @workflow_env "SYMPHONY_WORKFLOW_PATH"
  @logs_env "SYMPHONY_LOGS_ROOT"
  @state_env "SYMPHONY_STATE_ROOT"
  @workspaces_env "SYMPHONY_WORKSPACES_ROOT"
  @control_token_file_env "SYMPHONY_CONTROL_TOKEN_FILE"
  @worker_host_env "SYMPHONY_WINDOWS_WORKER_HOST"
  @host_env "SYMPHONY_SERVER_HOST"
  @port_env "SYMPHONY_SERVER_PORT"

  @doc """
  Applies installed-runtime settings when the managed launcher contract is
  present. Source and test runs with no launcher contract remain unchanged.
  """
  @spec prepare!() :: :ok
  def prepare! do
    case System.get_env(@managed_env) do
      nil ->
        :ok

      value when value in ["1", "true", "TRUE"] ->
        workflow = required_file!(@workflow_env)
        logs_root = required_absolute_path!(@logs_env)
        state_root = required_absolute_path!(@state_env)
        workspaces_root = required_absolute_path!(@workspaces_env)
        control_token_file = required_file!(@control_token_file_env)
        _worker_host = required_file!(@worker_host_env)
        host = required_loopback_host!()
        port = required_port!()

        Application.put_env(:symphony_elixir, :workflow_file_path, workflow)
        Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
        Application.put_env(:symphony_elixir, :managed_state_root, state_root)
        Application.put_env(:symphony_elixir, :workspace_root_override, workspaces_root)
        Application.put_env(:symphony_elixir, :control_token_file_override, control_token_file)
        Application.put_env(:symphony_elixir, :server_host_override, host)
        Application.put_env(:symphony_elixir, :server_port_override, port)
        Application.put_env(:symphony_elixir, :managed_mode, true)
        :ok

      value ->
        raise ArgumentError,
              "invalid #{@managed_env}=#{inspect(value)}; installed runtime requires true"
    end
  end

  defp required_file!(name) do
    path = required_absolute_path!(name)

    if File.regular?(path) do
      path
    else
      raise ArgumentError, "#{name} is not a regular file: #{path}"
    end
  end

  defp required_absolute_path!(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        path = String.trim(value)

        if path != "" and Path.type(path) == :absolute do
          Path.expand(path)
        else
          raise ArgumentError, "#{name} must be an absolute Windows path"
        end

      _ ->
        raise ArgumentError, "missing required installed-runtime setting #{name}"
    end
  end

  defp required_loopback_host! do
    case System.get_env(@host_env) do
      "127.0.0.1" -> "127.0.0.1"
      _ -> raise ArgumentError, "#{@host_env} must be 127.0.0.1"
    end
  end

  defp required_port! do
    value = System.get_env(@port_env)

    case Integer.parse(value || "") do
      {port, ""} when port in 1..65_535 -> port
      _ -> raise ArgumentError, "#{@port_env} must be an integer from 1 through 65535"
    end
  end
end
