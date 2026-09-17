defmodule SymphonyElixir.Managed.Requirements do
  @moduledoc """
  Reads the canonical project requirements bound by the managed operator.

  Worker input is derived only from a project binding, never from an
  assignment request. This keeps a caller from selecting an arbitrary local
  file for injection into a worker prompt.
  """

  @file_name "REQUIREMENTS.md"
  @max_bytes 128 * 1024

  @type snapshot :: %{path: Path.t(), content: String.t(), fingerprint: String.t()}

  @spec read(map()) :: {:ok, snapshot()} | {:error, atom()}
  def read(binding) when is_map(binding) do
    with {:ok, path} <- path(binding),
         {:ok, stat} <- File.lstat(path),
         :ok <- regular_size(stat),
         {:ok, content} <- File.read(path),
         :ok <- valid_content(content) do
      {:ok, %{path: path, content: content, fingerprint: fingerprint(content)}}
    else
      {:error, :enoent} -> {:error, :project_requirements_missing}
      {:error, _reason} -> {:error, :project_requirements_unreadable}
      {:invalid, reason} -> {:error, reason}
    end
  end

  def read(_binding), do: {:error, :project_requirements_path_invalid}

  @spec path(map()) :: {:ok, Path.t()} | {:error, :project_requirements_path_invalid}
  def path(binding) when is_map(binding) do
    value = Map.get(binding, :requirements_path, Map.get(binding, "requirements_path"))

    if is_binary(value) and Path.type(value) == :absolute and Path.basename(value) == @file_name do
      {:ok, Path.expand(value)}
    else
      {:error, :project_requirements_path_invalid}
    end
  end

  def path(_binding), do: {:error, :project_requirements_path_invalid}

  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(content) when is_binary(content) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
  end

  defp regular_size(%File.Stat{type: :regular, size: size}) when size <= @max_bytes, do: :ok
  defp regular_size(%File.Stat{type: :regular}), do: {:invalid, :project_requirements_too_large}
  defp regular_size(_stat), do: {:invalid, :project_requirements_not_regular_file}

  defp valid_content(content) do
    if String.valid?(content), do: :ok, else: {:invalid, :project_requirements_invalid_encoding}
  end
end