defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates local, owned workspaces for Codex workers on Windows.

  A workspace is never inferred from a recorded path alone. Its ownership
  record lives under the configured root, so a checkout may remain empty while
  an after-create hook initializes it.
  """

  require Logger

  alias SymphonyElixir.{Config, HookContext, PathSafety, WindowsWorkerHost}

  @ownership_directory ".symphony-owned-workspaces"
  @ownership_version 1

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    key = workspace_key(issue_or_identifier)

    with {:ok, root} <- configured_root(),
         {:ok, workspace} <- workspace_path(root, key),
         {:ok, created?} <- ensure_owned_workspace(workspace, root, key, issue_or_identifier),
         :ok <- maybe_run_after_create_hook(workspace, issue_or_identifier, created?) do
      {:ok, workspace}
    else
      {:error, reason} = error ->
        Logger.error("Workspace creation failed key=#{key} reason=#{inspect(reason)}")
        error
    end
  rescue
    error in [ArgumentError, ErlangError, File.Error] ->
      {:error, {:workspace_create_failed, Exception.message(error)}}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove_owned(workspace)

  @doc false
  @spec remove_recorded(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace), do: remove_owned(workspace)

  @doc false
  @spec validate_owned_workspace(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def validate_owned_workspace(workspace) when is_binary(workspace) do
    with {:ok, root} <- configured_root(),
         {:ok, canonical_workspace, canonical_root} <- PathSafety.descendant(workspace, root),
         :ok <- ensure_owned_record(canonical_workspace, canonical_root),
         true <- File.dir?(canonical_workspace),
         :ok <- reject_reparse_tree(canonical_workspace) do
      {:ok, canonical_workspace}
    else
      false -> {:error, {:workspace_not_directory, workspace}}
      {:error, {:outside_root, _path, _root}} -> {:error, {:workspace_outside_root, workspace}}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_owned_workspace(workspace), do: {:error, {:workspace_path_unreadable, workspace, :invalid}}

  @doc false
  @spec worker_process_identity_path(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def worker_process_identity_path(workspace) when is_binary(workspace) do
    with {:ok, root} <- configured_root(),
         {:ok, canonical_workspace} <- validate_owned_workspace(workspace),
         :ok <- ensure_owned_record(canonical_workspace, root) do
      ownership = ownership_path(root, canonical_workspace)
      {:ok, Path.join(Path.dirname(ownership), "process-" <> Path.basename(ownership))}
    end
  end

  def worker_process_identity_path(workspace),
    do: {:error, {:workspace_path_unreadable, workspace, :invalid}}

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) do
    with {:ok, root} <- configured_root(),
         {:ok, workspace} <- workspace_path(root, workspace_key(identifier)) do
      _ = remove_owned(workspace)
    end

    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) do
    with {:ok, canonical_workspace} <- validate_owned_workspace(workspace) do
      run_configured_hook(:before_run, canonical_workspace, issue_or_identifier, false)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) do
    with {:ok, canonical_workspace} <- validate_owned_workspace(workspace) do
      _ = run_configured_hook(:after_run, canonical_workspace, issue_or_identifier, true)
    end

    :ok
  end

  @doc """
  Returns a short opaque directory name. The identifier is never included in a
  Windows path, avoiding case, Unicode, and separator collisions.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)
  def workspace_key(%{"identifier" => identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    digest = :crypto.hash(:sha256, identifier) |> Base.encode16(case: :lower)
    "w-" <> binary_part(digest, 0, 24)
  end

  def workspace_key(_identifier), do: "w-" <> String.duplicate("0", 24)

  defp configured_root do
    raw_root = Config.local_workspace_root()

    with {:ok, expanded_root} <- PathSafety.canonicalize(raw_root),
         :ok <- ensure_root_directory(expanded_root),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root),
         true <- File.dir?(canonical_root),
         {:ok, false} <- PathSafety.reparse_point?(canonical_root) do
      {:ok, canonical_root}
    else
      false -> {:error, {:workspace_root_invalid, raw_root}}
      {:ok, true} -> {:error, {:workspace_root_reparse_point, raw_root}}
      {:error, reason} -> {:error, {:workspace_root_invalid, raw_root, reason}}
    end
  end

  defp ensure_root_directory(root) do
    case File.mkdir_p(root) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_path(root, key) do
    candidate = Path.join(root, key)

    case PathSafety.descendant(candidate, root) do
      {:ok, workspace, _root} -> {:ok, workspace}
      {:error, reason} -> {:error, {:workspace_path_invalid, candidate, reason}}
    end
  end

  defp ensure_owned_workspace(workspace, root, key, issue_or_identifier) do
    case File.lstat(workspace) do
      {:error, :enoent} ->
        with :ok <- record_ownership(root, workspace, key, issue_or_identifier) do
          create_workspace(workspace, root, key, issue_or_identifier)
        end

      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- ensure_owned_record(workspace, root, key, issue_or_identifier),
             :ok <- reject_reparse_tree(workspace) do
          {:ok, false}
        end

      {:ok, _stat} ->
        {:error, {:workspace_unowned_or_not_directory, workspace}}

      {:error, reason} ->
        {:error, {:workspace_path_unreadable, workspace, reason}}
    end
  end

  defp create_workspace(workspace, root, key, issue_or_identifier) do
    case File.mkdir(workspace) do
      :ok ->
        {:ok, true}

      {:error, :eexist} ->
        validate_existing_workspace(workspace, root, key, issue_or_identifier)

      {:error, reason} ->
        {:error, {:workspace_create_failed, workspace, reason}}
    end
  end

  defp validate_existing_workspace(workspace, root, key, issue_or_identifier) do
    case File.lstat(workspace) do
      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- ensure_owned_record(workspace, root, key, issue_or_identifier),
             :ok <- reject_reparse_tree(workspace) do
          {:ok, false}
        end

      {:ok, _stat} ->
        {:error, {:workspace_unowned_or_not_directory, workspace}}

      {:error, reason} ->
        {:error, {:workspace_path_unreadable, workspace, reason}}
    end
  end

  defp remove_owned(workspace) when is_binary(workspace) do
    with {:ok, canonical_workspace} <- validate_owned_workspace(workspace),
         :ok <- maybe_run_before_remove_hook(canonical_workspace),
         {:ok, removed} <- File.rm_rf(canonical_workspace),
         :ok <- remove_ownership_record(canonical_workspace) do
      {:ok, removed}
    else
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp remove_owned(workspace), do: {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}

  defp maybe_run_after_create_hook(_workspace, _issue, false), do: :ok

  defp maybe_run_after_create_hook(workspace, issue, true) do
    case run_configured_hook(:after_create, workspace, issue, false) do
      :ok ->
        :ok

      {:error, reason} ->
        case remove_owned(workspace) do
          {:ok, _removed} ->
            {:error, reason}

          {:error, cleanup_reason, _output} ->
            {:error, {:workspace_hook_cleanup_refused, reason, cleanup_reason}}
        end
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    case run_configured_hook(:before_remove, workspace, nil, true) do
      :ok -> :ok
      # A before-remove hook is advisory, preserving the previous lifecycle
      # behavior while its invocation remains safely scoped to this workspace.
      {:error, _reason} -> :ok
    end
  end

  defp run_configured_hook(kind, workspace, issue_or_identifier, ignore_failure?) do
    command = Map.fetch!(Config.settings!().hooks, kind)

    if is_nil(command) do
      :ok
    else
      with {:ok, context} <- HookContext.encode(issue_context(issue_or_identifier)),
           {:ok, executable} <- powershell_executable() do
        run_powershell_hook(executable, command, workspace, context, Atom.to_string(kind), ignore_failure?)
      else
        {:error, reason} -> {:error, {:workspace_hook_context_rejected, Atom.to_string(kind), reason}}
      end
    end
  end

  defp powershell_executable do
    case System.find_executable("pwsh") || System.find_executable("powershell") do
      nil -> {:error, :powershell_not_found}
      executable -> {:ok, executable}
    end
  end

  defp run_powershell_hook(executable, command, workspace, context, hook_name, ignore_failure?) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    result =
      case WindowsWorkerHost.start(workspace, executable, powershell_arguments(command), nil, [
             {String.to_charlist(HookContext.env_name()), String.to_charlist(context)}
           ]) do
        {:ok, port, metadata} -> await_hook_port(port, metadata, timeout_ms, "", hook_name)
        {:error, reason} -> {:error, {:workspace_hook_start_failed, hook_name, reason}}
      end

    case {ignore_failure?, result} do
      {true, {:error, reason}} ->
        Logger.warning("Workspace hook failed hook=#{hook_name} workspace=#{workspace} reason=#{inspect(reason)}")
        :ok

      _ ->
        result
    end
  end

  defp powershell_arguments(command) do
    encoded =
      command
      |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
      |> Base.encode64()

    ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]
  end

  defp await_hook_port(port, metadata, timeout_ms, output, hook_name) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        await_hook_port(port, metadata, timeout_ms, output <> to_string(chunk) <> "\n", hook_name)

      {^port, {:data, {:noeol, chunk}}} ->
        await_hook_port(port, metadata, timeout_ms, output <> to_string(chunk), hook_name)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:workspace_hook_failed, hook_name, status, output}}
    after
      timeout_ms ->
        case WindowsWorkerHost.stop_recorded(metadata) do
          :ok ->
            close_hook_port(port)
            {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}

          {:error, reason} ->
            {:error, {:workspace_hook_timeout_stop_unconfirmed, hook_name, timeout_ms, reason}}
        end
    end
  end

  defp close_hook_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp ownership_path(root, workspace) do
    digest = :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower)
    Path.join([root, @ownership_directory, binary_part(digest, 0, 32) <> ".json"])
  end

  defp ownership_record(_root, workspace, key, issue_or_identifier) do
    %{
      "version" => @ownership_version,
      "workspace" => workspace,
      "workspace_key" => key,
      "issue_identifier_hash" => issue_identifier_hash(issue_or_identifier)
    }
  end

  defp record_ownership(root, workspace, key, issue_or_identifier) do
    path = ownership_path(root, workspace)
    record = ownership_record(root, workspace, key, issue_or_identifier)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, false} <- PathSafety.reparse_point?(Path.dirname(path)) do
      case File.write(path, Jason.encode!(record) <> "\n", [:write, :exclusive]) do
        :ok -> :ok
        {:error, :eexist} -> ensure_owned_record(workspace, root, key, issue_or_identifier)
        {:error, reason} -> {:error, {:workspace_ownership_record_failed, reason}}
      end
    else
      {:ok, true} -> {:error, {:workspace_ownership_reparse_point, path}}
      {:error, reason} -> {:error, {:workspace_ownership_record_failed, reason}}
    end
  end

  defp ensure_owned_record(workspace, root, expected_key \\ nil, issue_or_identifier \\ nil) do
    path = ownership_path(root, workspace)

    with {:ok, raw} <- File.read(path),
         {:ok, record} <- Jason.decode(raw),
         true <- record["version"] == @ownership_version,
         true <- is_binary(record["workspace"]) and PathSafety.same_path?(record["workspace"], workspace),
         true <- is_nil(expected_key) or record["workspace_key"] == expected_key,
         true <- is_nil(issue_or_identifier) or record["issue_identifier_hash"] == issue_identifier_hash(issue_or_identifier) do
      :ok
    else
      false -> {:error, {:workspace_ownership_mismatch, workspace}}
      {:error, _reason} -> {:error, {:workspace_unowned, workspace}}
    end
  end

  defp remove_ownership_record(workspace) do
    with {:ok, root} <- configured_root(),
         :ok <- ensure_owned_record(workspace, root) do
      case File.rm(ownership_path(root, workspace)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:workspace_ownership_remove_failed, reason}}
      end
    end
  end

  defp reject_reparse_tree(workspace) do
    case File.ls(workspace) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, &reject_reparse_entry(workspace, &1, &2))

      {:error, reason} ->
        {:error, {:workspace_path_unreadable, workspace, reason}}
    end
  end

  defp reject_reparse_entry(workspace, entry, :ok) do
    path = Path.join(workspace, entry)

    case PathSafety.reparse_point?(path) do
      {:ok, true} -> {:halt, {:error, {:workspace_reparse_point, path}}}
      {:error, reason} -> {:halt, {:error, {:workspace_path_unreadable, path, reason}}}
      {:ok, false} -> continue_reparse_scan(path)
    end
  end

  defp continue_reparse_scan(path) do
    result = if File.dir?(path), do: recurse_reparse_tree(path), else: :ok

    case result do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp recurse_reparse_tree(path), do: reject_reparse_tree(path)

  defp issue_identifier_hash(%{identifier: identifier}), do: issue_identifier_hash(identifier)
  defp issue_identifier_hash(%{"identifier" => identifier}), do: issue_identifier_hash(identifier)

  defp issue_identifier_hash(identifier) when is_binary(identifier),
    do: :crypto.hash(:sha256, identifier) |> Base.encode16(case: :lower)

  defp issue_identifier_hash(_identifier), do: nil

  defp issue_context(%{id: id, identifier: identifier} = issue),
    do: %{id: id, identifier: identifier, native_ref: Map.get(issue, :native_ref)}

  defp issue_context(%{"id" => id, "identifier" => identifier} = issue),
    do: %{id: id, identifier: identifier, native_ref: Map.get(issue, "native_ref")}

  defp issue_context(identifier) when is_binary(identifier), do: %{id: nil, identifier: identifier, native_ref: nil}
  defp issue_context(_issue), do: %{id: nil, identifier: nil, native_ref: nil}
end
