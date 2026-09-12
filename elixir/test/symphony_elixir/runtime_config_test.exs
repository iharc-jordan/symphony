defmodule SymphonyElixir.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{LogFile, RuntimeConfig}

  @variables [
    "SYMPHONY_MANAGED",
    "SYMPHONY_WORKFLOW_PATH",
    "SYMPHONY_LOGS_ROOT",
    "SYMPHONY_STATE_ROOT",
    "SYMPHONY_WORKSPACES_ROOT",
    "SYMPHONY_CONTROL_TOKEN_FILE",
    "SYMPHONY_WINDOWS_WORKER_HOST",
    "SYMPHONY_SERVER_HOST",
    "SYMPHONY_SERVER_PORT"
  ]

  @app_keys [
    :workflow_file_path,
    :log_file,
    :managed_state_root,
    :workspace_root_override,
    :control_token_file_override,
    :server_host_override,
    :server_port_override,
    :managed_mode
  ]

  setup do
    old_env = Map.new(@variables, &{&1, System.get_env(&1)})
    old_app = Map.new(@app_keys, &{&1, Application.get_env(:symphony_elixir, &1)})

    on_exit(fn ->
      Enum.each(old_env, fn {name, value} -> restore_system_env(name, value) end)
      Enum.each(old_app, fn {key, value} -> restore_app_env(key, value) end)
    end)

    Enum.each(@variables, &System.delete_env/1)
    Enum.each(@app_keys, &Application.delete_env(:symphony_elixir, &1))
    :ok
  end

  test "does nothing for source runs without the installed launcher contract" do
    assert :ok = RuntimeConfig.prepare!()
    refute Application.get_env(:symphony_elixir, :managed_mode)
  end

  test "applies validated absolute launcher inputs before application startup" do
    root = Path.join(System.tmp_dir!(), "symphony-runtime-config-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    workflow = Path.join(root, "config/WORKFLOW.md")
    logs = Path.join(root, "logs")
    state = Path.join(root, "state")
    workspaces = Path.join(root, "workspaces")
    token_file = Path.join(root, "config/token")
    worker_host = Path.join(root, "symphony-worker-host.exe")
    File.mkdir_p!(Path.dirname(workflow))
    File.write!(workflow, "---\n---\n")
    File.write!(token_file, "test-token\n")
    File.write!(worker_host, "fixture")

    System.put_env(%{
      "SYMPHONY_MANAGED" => "true",
      "SYMPHONY_WORKFLOW_PATH" => workflow,
      "SYMPHONY_LOGS_ROOT" => logs,
      "SYMPHONY_STATE_ROOT" => state,
      "SYMPHONY_WORKSPACES_ROOT" => workspaces,
      "SYMPHONY_CONTROL_TOKEN_FILE" => token_file,
      "SYMPHONY_WINDOWS_WORKER_HOST" => worker_host,
      "SYMPHONY_SERVER_HOST" => "127.0.0.1",
      "SYMPHONY_SERVER_PORT" => "8787"
    })

    assert :ok = RuntimeConfig.prepare!()
    assert Application.get_env(:symphony_elixir, :workflow_file_path) == Path.expand(workflow)
    assert Application.get_env(:symphony_elixir, :log_file) == LogFile.default_log_file(Path.expand(logs))
    assert Application.get_env(:symphony_elixir, :managed_state_root) == Path.expand(state)
    assert Application.get_env(:symphony_elixir, :workspace_root_override) == Path.expand(workspaces)
    assert Application.get_env(:symphony_elixir, :control_token_file_override) == Path.expand(token_file)
    assert Application.get_env(:symphony_elixir, :server_host_override) == "127.0.0.1"
    assert Application.get_env(:symphony_elixir, :server_port_override) == 8787
    assert Application.get_env(:symphony_elixir, :managed_mode)
  end

  test "rejects a non-loopback installed endpoint" do
    root = Path.join(System.tmp_dir!(), "symphony-runtime-config-host-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    workflow = Path.join(root, "WORKFLOW.md")
    token_file = Path.join(root, "token")
    worker_host = Path.join(root, "symphony-worker-host.exe")
    File.mkdir_p!(root)
    File.write!(workflow, "---\n---\n")
    File.write!(token_file, "test-token\n")
    File.write!(worker_host, "fixture")

    System.put_env(%{
      "SYMPHONY_MANAGED" => "true",
      "SYMPHONY_WORKFLOW_PATH" => workflow,
      "SYMPHONY_LOGS_ROOT" => Path.join(root, "logs"),
      "SYMPHONY_STATE_ROOT" => Path.join(root, "state"),
      "SYMPHONY_WORKSPACES_ROOT" => Path.join(root, "workspaces"),
      "SYMPHONY_CONTROL_TOKEN_FILE" => token_file,
      "SYMPHONY_WINDOWS_WORKER_HOST" => worker_host,
      "SYMPHONY_SERVER_HOST" => "0.0.0.0",
      "SYMPHONY_SERVER_PORT" => "8787"
    })

    assert_raise ArgumentError, ~r/SYMPHONY_SERVER_HOST must be 127\.0\.0\.1/, fn ->
      RuntimeConfig.prepare!()
    end
  end

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
