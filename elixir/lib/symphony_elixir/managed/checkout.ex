defmodule SymphonyElixir.Managed.Checkout do
  @moduledoc """
  Prepares an owned worker workspace directly with Git.

  Checkout authority is the provider identity and pinned commit already stored
  on the managed assignment. No plugin, Node runtime, policy file, or staging
  input participates in the checkout path.
  """

  alias SymphonyElixir.Workspace

  @default_timeout_ms 300_000

  @spec prepare(Path.t(), map(), map(), map(), keyword()) :: :ok | {:error, term()}
  def prepare(workspace, issue, assignment, attempt, opts) do
    base_commit = Map.get(assignment, :base_commit)

    with {:ok, workspace} <- Workspace.validate_owned_workspace(workspace),
         :ok <- validate_attempt(issue, assignment, attempt),
         {:ok, repository_url} <- repository_url(opts, assignment),
         {:ok, git} <- git_executable(opts) do
      checkout_owned_workspace(workspace, git, repository_url, base_commit, opts)
    end
  rescue
    error in [ArgumentError, File.Error, ErlangError] ->
      {:error, {:managed_checkout_failed, error.__struct__}}
  end

  defp validate_attempt(issue, assignment, attempt) do
    id = Map.get(assignment, :assignment_id)
    attempt_id = Map.get(attempt, :attempt_id)
    base = Map.get(assignment, :base_commit)
    repository = Map.get(assignment, :repository)

    if valid_assignment_identity?(id, issue, attempt) and
         valid_revision_identity?(assignment, attempt) and
         valid_attempt_identity?(attempt_id, attempt) and
         valid_checkout_source?(base, repository) do
      :ok
    else
      {:error, :checkout_attempt_identity_invalid}
    end
  end

  defp valid_assignment_identity?(id, issue, attempt) do
    is_binary(id) and id != "" and id == Map.get(issue, :id) and
      id == Map.get(attempt, :assignment_id)
  end

  defp valid_revision_identity?(assignment, attempt) do
    revision = Map.get(assignment, :revision)
    is_integer(revision) and revision >= 0 and revision == Map.get(attempt, :revision)
  end

  defp valid_attempt_identity?(attempt_id, attempt) do
    generation = Map.get(attempt, :generation)

    is_binary(attempt_id) and byte_size(attempt_id) in 1..150 and
      is_integer(generation) and generation >= 0
  end

  defp valid_checkout_source?(base, repository) do
    is_binary(base) and Regex.match?(~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/, base) and
      is_binary(repository) and String.trim(repository) != ""
  end

  defp repository_url(opts, assignment) do
    url = Keyword.get(opts, :repository_url)

    cond do
      is_binary(url) and String.trim(url) != "" and safe_repository_url?(url) -> {:ok, String.trim(url)}
      is_binary(url) -> {:error, :checkout_repository_url_invalid}
      true -> {:error, {:checkout_repository_url_missing, Map.get(assignment, :repository)}}
    end
  end

  # Provider-authorized HTTPS URLs and configured local mirrors are the only
  # checkout inputs used by the local Windows worker.
  defp safe_repository_url?(url) do
    String.starts_with?(url, "https://") or
      String.starts_with?(url, "http://") or
      Path.type(url) == :absolute
  end

  defp git_executable(opts) do
    case Keyword.get(opts, :git_executable, System.find_executable("git")) do
      executable when is_binary(executable) and executable != "" -> {:ok, executable}
      _ -> {:error, :git_not_found}
    end
  end

  defp checkout_owned_workspace(workspace, git, repository_url, base_commit, opts) do
    case File.ls(workspace) do
      {:ok, []} -> initialize_checkout(workspace, git, repository_url, base_commit, opts)
      {:ok, _entries} -> validate_existing_checkout(workspace, git, repository_url, base_commit, opts)
      {:error, reason} -> {:error, {:checkout_workspace_unreadable, reason}}
    end
  end

  defp initialize_checkout(workspace, git, repository_url, base_commit, opts) do
    with :ok <- git!(git, ["init"], workspace, opts),
         :ok <- git!(git, ["remote", "add", "origin", repository_url], workspace, opts),
         :ok <- git!(git, ["fetch", "--no-tags", "origin", base_commit], workspace, opts),
         :ok <- git!(git, ["checkout", "--detach", "--force", base_commit], workspace, opts),
         :ok <- verify_checkout(workspace, git, repository_url, base_commit, opts) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_existing_checkout(workspace, git, repository_url, base_commit, opts) do
    with :ok <- git!(git, ["rev-parse", "--is-inside-work-tree"], workspace, opts),
         :ok <- verify_checkout(workspace, git, repository_url, base_commit, opts),
         :ok <- ensure_clean_checkout(workspace, git, opts) do
      :ok
    else
      {:error, {:checkout_command_failed, _command, _status, _output}} ->
        {:error, :checkout_workspace_conflict}

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_checkout(workspace, git, repository_url, base_commit, opts) do
    with {:ok, actual_url} <- git_output(git, ["remote", "get-url", "origin"], workspace, opts),
         true <- same_repository_url?(actual_url, repository_url),
         {:ok, actual_commit} <- git_output(git, ["rev-parse", "HEAD"], workspace, opts),
         true <- String.downcase(String.trim(actual_commit)) == String.downcase(base_commit) do
      :ok
    else
      false -> {:error, :checkout_identity_or_commit_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_clean_checkout(workspace, git, opts) do
    with {:ok, status} <- git_output(git, ["status", "--porcelain=v1", "--untracked-files=all"], workspace, opts),
         true <- String.trim(status) == "" do
      :ok
    else
      false -> {:error, :checkout_workspace_has_unaccepted_work}
      {:error, _reason} = error -> error
    end
  end

  defp git!(git, arguments, workspace, opts) do
    case git_output(git, arguments, workspace, opts) do
      {:ok, _output} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp git_output(git, arguments, workspace, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    task = Task.async(fn -> System.cmd(git, arguments, cd: workspace, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} ->
        {:error, {:checkout_command_failed, arguments, status, trim_output(output)}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:checkout_command_timeout, arguments, timeout_ms}}
    end
  end

  defp same_repository_url?(actual, expected) do
    normalize_repository_url(actual) == normalize_repository_url(expected)
  end

  defp normalize_repository_url(value) do
    value
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp trim_output(output) when is_binary(output), do: output |> String.trim() |> String.slice(0, 2_048)
end
