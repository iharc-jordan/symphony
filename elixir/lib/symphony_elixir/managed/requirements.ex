defmodule SymphonyElixir.Managed.Requirements do
  @moduledoc """
  Reads the canonical project requirements bound by the managed operator.

  Worker input is derived only from a project binding, never from an
  assignment request. This keeps a caller from selecting an arbitrary local
  file for injection into a worker prompt.
  """

  @file_name "REQUIREMENTS.md"

  @type snapshot :: %{path: Path.t(), content: String.t(), fingerprint: String.t()}

  @spec read(map()) :: {:ok, snapshot()} | {:error, atom()}
  def read(binding) when is_map(binding) do
    with {:ok, path} <- path(binding),
         {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, content} <- File.read(path) do
      {:ok, %{path: path, content: content, fingerprint: fingerprint(content)}}
    else
      {:ok, _} -> {:error, :project_requirements_not_regular_file}
      {:error, :enoent} -> {:error, :project_requirements_missing}
      {:error, _reason} -> {:error, :project_requirements_unreadable}
    end
  end

  def read(_binding), do: {:error, :project_requirements_path_invalid}

  @spec path(map()) :: {:ok, Path.t()} | {:error, :project_requirements_path_invalid}
  def path(binding) when is_map(binding) do
    value = Map.get(binding, :requirements_path, Map.get(binding, "requirements_path"))

    if is_binary(value) and Path.type(value) == :absolute and Path.basename(value) == @file_name and
         Path.expand(value) == value do
      {:ok, value}
    else
      {:error, :project_requirements_path_invalid}
    end
  end

  def path(_binding), do: {:error, :project_requirements_path_invalid}

  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(content) when is_binary(content) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
  end
end
