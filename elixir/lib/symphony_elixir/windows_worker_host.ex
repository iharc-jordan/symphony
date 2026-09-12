defmodule SymphonyElixir.WindowsWorkerHost do
  @moduledoc false

  alias SymphonyElixir.Workspace

  # This is intentionally a thin adapter over the small native helper. Elixir
  # owns application protocol; the helper owns only Win32 process and Job
  # Object operations.

  @identity_wait_ms 1_000

  @spec start(Path.t(), Path.t(), [String.t()], map() | nil, list()) ::
          {:ok, port(), map()} | {:error, term()}
  def start(workspace, executable, arguments, attempt, secret_env)
      when is_binary(workspace) and is_binary(executable) and is_list(arguments) and is_list(secret_env) do
    with {:ok, helper} <- helper_executable(),
         :ok <- validate_command(executable, arguments),
         {:ok, identity_file} <- identity_file(workspace),
         {:ok, job_name} <- job_name(attempt, workspace) do
      port =
        Port.open({:spawn_executable, String.to_charlist(helper)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args:
            helper_arguments(
              identity_file,
              workspace,
              job_name,
              attempt_id(attempt),
              executable,
              arguments
            ),
          cd: String.to_charlist(workspace),
          env: secret_env,
          line: 1_048_576
        ])

      case await_identity(identity_file, @identity_wait_ms) do
        {:ok, identity} ->
          {:ok, port, Map.put(identity, :identity_file, identity_file)}

        {:error, reason} ->
          close_port(port)
          {:error, reason}
      end
    end
  end

  @spec stop_recorded(map()) :: :ok | {:error, term()}
  def stop_recorded(%{job_name: job_name, child_pid: pid, child_creation_time: creation_time})
      when is_binary(job_name) and is_integer(pid) and is_integer(creation_time) do
    with {:ok, helper} <- helper_executable() do
      case System.cmd(
             helper,
             [
               "--stop",
               "--job-name",
               job_name,
               "--pid",
               Integer.to_string(pid),
               "--creation-time",
               Integer.to_string(creation_time)
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:windows_job_stop_failed, status, String.trim(output)}}
      end
    end
  rescue
    error -> {:error, {:windows_job_stop_exception, Exception.message(error)}}
  end

  def stop_recorded(_metadata), do: {:error, :windows_job_identity_missing}

  @spec reparse_point?(Path.t()) :: {:ok, boolean()} | {:error, term()}
  def reparse_point?(path) when is_binary(path) do
    with {:ok, helper} <- helper_executable() do
      case System.cmd(helper, ["--is-reparse", "--path", path], stderr_to_stdout: true) do
        {_output, 0} -> {:ok, false}
        {_output, 3} -> {:ok, true}
        {output, status} -> {:error, {:windows_reparse_probe_failed, status, String.trim(output)}}
      end
    end
  rescue
    error -> {:error, {:windows_reparse_probe_exception, Exception.message(error)}}
  end

  def reparse_point?(_path), do: {:error, :invalid_path}

  @spec helper_available?() :: boolean()
  def helper_available? do
    match?({:ok, _path}, helper_executable())
  end

  defp helper_arguments(identity_file, workspace, job_name, attempt_id, executable, arguments) do
    [
      "--parent-pid",
      System.pid(),
      "--job-name",
      job_name,
      "--identity-file",
      identity_file,
      "--cwd",
      workspace,
      "--attempt-id",
      attempt_id,
      "--",
      executable
    ]
    |> Kernel.++(arguments)
    |> Enum.map(&String.to_charlist/1)
  end

  defp helper_executable do
    configured = System.get_env("SYMPHONY_WINDOWS_WORKER_HOST")

    candidates =
      [configured]
      |> Enum.reject(&(not is_binary(&1) or String.trim(&1) == ""))
      |> Kernel.++(development_helper_candidates())

    case Enum.find(candidates, &File.regular?/1) do
      nil -> {:error, :windows_worker_host_not_found}
      executable -> {:ok, executable}
    end
  end

  defp development_helper_candidates do
    base = Path.join([File.cwd!(), "native", "symphony_worker_host", "target"])
    [Path.join([base, "release", "symphony-worker-host.exe"]), Path.join([base, "debug", "symphony-worker-host.exe"])]
  end

  defp validate_command(executable, arguments) do
    cond do
      not File.regular?(executable) -> {:error, :worker_executable_not_found}
      not Enum.all?(arguments, &is_binary/1) -> {:error, :invalid_worker_arguments}
      true -> :ok
    end
  end

  defp identity_file(workspace) do
    with {:ok, path} <- Workspace.worker_process_identity_path(workspace) do
      case File.rm(path) do
        :ok -> {:ok, path}
        {:error, :enoent} -> {:ok, path}
        {:error, reason} -> {:error, {:worker_identity_file_unavailable, reason}}
      end
    end
  end

  defp job_name(attempt, workspace) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    identity = [attempt_id(attempt), workspace, nonce] |> Enum.join("\0")
    digest = :crypto.hash(:sha256, identity) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    {:ok, "symphony-" <> digest}
  end

  defp attempt_id(%{attempt_id: attempt_id}) when is_binary(attempt_id) and attempt_id != "", do: attempt_id
  defp attempt_id(_attempt), do: "local-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp await_identity(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_identity_until(path, deadline)
  end

  defp await_identity_until(path, deadline) do
    case File.read(path) do
      {:ok, raw} ->
        decode_identity(raw)

      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_identity_until(path, deadline)
        else
          {:error, :worker_identity_timeout}
        end

      {:error, reason} ->
        {:error, {:worker_identity_unreadable, reason}}
    end
  end

  defp decode_identity(raw) do
    with {:ok, %{"job_name" => job_name, "child_pid" => pid, "child_creation_time" => creation_time} = identity} <-
           Jason.decode(raw),
         true <-
           is_binary(job_name) and is_integer(pid) and pid > 0 and is_integer(creation_time) and
             creation_time > 0 do
      {:ok,
       %{
         containment: :windows_job,
         job_name: job_name,
         child_pid: pid,
         child_creation_time: creation_time,
         attempt_id: Map.get(identity, "attempt_id")
       }}
    else
      false -> {:error, :worker_identity_invalid}
      {:error, _reason} -> {:error, :worker_identity_invalid}
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
