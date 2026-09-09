defmodule SymphonyElixir.Managed.Checkout do
  @moduledoc """
  Prepares an enrolled checkout through the installed plugin's trusted helper.

  The orchestrator supplies assignment and attempt records after reserving their
  ownership. Inputs are immutable, private files outside all worker workspaces;
  they remain available when preparation fails or execution is interrupted.
  """

  import Bitwise
  alias SymphonyElixir.{HookContext, PathSafety}

  @max_policy_bytes 16 * 1024

  @spec prepare(Path.t(), map(), map(), map(), keyword()) :: :ok | {:error, term()}
  def prepare(workspace, issue, assignment, attempt, opts) do
    with {:ok, node} <- absolute_option(opts, :node_executable),
         {:ok, helper} <- absolute_option(opts, :helper_path),
         {:ok, policy_file} <- absolute_option(opts, :policy_file),
         {:ok, policy} <- read_policy(policy_file),
         {:ok, paths} <- resolve_paths(workspace, policy_file, helper, node, policy),
         {:ok, input} <- attempt_input(paths.workspace, issue, assignment, attempt),
         {:ok, context} <- HookContext.encode(issue),
         {:ok, input_file} <- write_input(paths.input_root, input) do
      invoke_helper(paths.node, paths.helper, paths.policy_file, input_file, paths.workspace, context)
    end
  rescue
    error in [ArgumentError, File.Error, ErlangError] ->
      {:error, {:managed_checkout_failed, error.__struct__}}
  end

  defp absolute_option(opts, key) do
    case Keyword.get(opts, key) do
      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute, do: {:ok, path}, else: {:error, {:checkout_absolute_path_required, key}}

      _ ->
        {:error, {:checkout_configuration_missing, key}}
    end
  end

  defp read_policy(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_policy_bytes <- File.stat(path),
         {:ok, raw} <- File.read(path),
         {:ok, %{"control_root" => control, "workspace_root" => workspaces} = policy}
         when is_binary(control) and is_binary(workspaces) <- Jason.decode(raw),
         true <- Path.type(control) == :absolute and Path.type(workspaces) == :absolute do
      {:ok, policy}
    else
      _ -> {:error, :checkout_policy_invalid}
    end
  end

  defp resolve_paths(workspace, policy_file, helper, node, policy) do
    with true <- is_binary(workspace) and Path.type(workspace) == :absolute,
         {:ok, control_root} <- PathSafety.canonicalize(policy["control_root"]),
         {:ok, workspace_root} <- PathSafety.canonicalize(policy["workspace_root"]),
         {:ok, workspace} <- PathSafety.canonicalize(workspace),
         {:ok, policy_file} <- PathSafety.canonicalize(policy_file),
         {:ok, helper} <- PathSafety.canonicalize(helper),
         {:ok, node} <- PathSafety.canonicalize(node),
         {:ok, input_root} <- PathSafety.canonicalize(Path.join(control_root, "attempts")),
         true <- descendant?(workspace, workspace_root),
         false <- within?(input_root, workspace_root),
         false <- within?(policy_file, workspace_root),
         false <- within?(helper, workspace_root),
         false <- within?(node, workspace_root),
         true <- descendant?(input_root, control_root) do
      {:ok, %{workspace: workspace, input_root: input_root, node: node, helper: helper, policy_file: policy_file}}
    else
      _ -> {:error, :checkout_path_boundary_invalid}
    end
  end

  defp descendant?(path, root), do: String.starts_with?(path, String.trim_trailing(root, "/") <> "/")
  defp within?(path, root), do: path == root or descendant?(path, root)

  defp attempt_input(workspace, issue, assignment, attempt) do
    id = Map.get(assignment, :assignment_id)
    attempt_id = Map.get(attempt, :attempt_id)
    base = Map.get(assignment, :base_commit)
    repository = Map.get(assignment, :repository)

    if current_identity?(issue, assignment, attempt) and valid_attempt_fields?(attempt_id, base, repository, attempt) do
      {:ok,
       %{
         "assignment_id" => id,
         "attempt_id" => attempt_id,
         "base_commit" => base,
         "repository" => repository,
         "workspace" => workspace,
         "revision" => attempt.revision,
         "generation" => attempt.generation
       }}
    else
      {:error, :checkout_attempt_identity_invalid}
    end
  end

  defp current_identity?(issue, assignment, attempt) do
    id = Map.get(assignment, :assignment_id)
    revision = Map.get(assignment, :revision)

    is_binary(id) and id != "" and id == Map.get(issue, :id) and id == Map.get(attempt, :assignment_id) and
      is_integer(revision) and revision >= 0 and revision == Map.get(attempt, :revision)
  end

  defp valid_attempt_fields?(attempt_id, base, repository, attempt) do
    is_binary(attempt_id) and byte_size(attempt_id) in 1..150 and
      is_binary(base) and Regex.match?(~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/, base) and
      is_binary(repository) and repository != "" and
      is_integer(Map.get(attempt, :generation)) and attempt.generation >= 0
  end

  defp write_input(root, input) do
    name = Base.url_encode64(input["attempt_id"], padding: false) <> ".json"
    path = Path.join(root, name)

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700) do
      create_or_reuse_input(path, input)
    end
  end

  defp create_or_reuse_input(path, input) do
    if File.exists?(path) do
      existing_input(path, input)
    else
      with :ok <- File.write(path, Jason.encode!(input) <> "\n", [:write, :exclusive]),
           :ok <- File.chmod(path, 0o600) do
        {:ok, path}
      end
    end
  end

  defp existing_input(path, expected) do
    with {:ok, %{type: :regular, mode: mode}} <- File.lstat(path),
         true <- band(mode, 0o077) == 0,
         {:ok, raw} <- File.read(path),
         {:ok, ^expected} <- Jason.decode(raw) do
      {:ok, path}
    else
      _ -> {:error, :checkout_input_conflict}
    end
  end

  defp invoke_helper(node, helper, policy, input, workspace, context) do
    case System.cmd(node, [helper, "checkout", "--input", input, "--policy", policy],
           cd: workspace,
           env: [{HookContext.env_name(), context}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:checkout_helper_failed, status}}
    end
  end
end
