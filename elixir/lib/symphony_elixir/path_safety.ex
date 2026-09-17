defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  alias SymphonyElixir.WindowsWorkerHost

  # Windows resolves paths case-insensitively and permits both separators. Do
  # not compare raw strings at callers: always use these boundary helpers.

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    with :ok <- valid_path?(path),
         true <- Path.type(path) == :absolute,
         expanded = Path.expand(path),
         :ok <- reject_reparse_components(expanded) do
      {:ok, expanded}
    else
      false -> {:error, {:path_not_absolute, path}}
      {:error, reason} -> {:error, {:path_canonicalize_failed, path, reason}}
    end
  end

  def canonicalize(path), do: {:error, {:path_canonicalize_failed, path, :invalid_path}}

  @doc false
  @spec descendant(Path.t(), Path.t()) :: {:ok, Path.t(), Path.t()} | {:error, term()}
  def descendant(path, root) when is_binary(path) and is_binary(root) do
    with {:ok, canonical_path} <- canonicalize(path),
         {:ok, canonical_root} <- canonicalize(root),
         true <- not same_path?(canonical_path, canonical_root),
         true <- within?(canonical_path, canonical_root) do
      {:ok, canonical_path, canonical_root}
    else
      false -> {:error, {:outside_root, path, root}}
      {:error, reason} -> {:error, reason}
    end
  end

  def descendant(path, root), do: {:error, {:invalid_path_boundary, path, root}}

  @doc false
  @spec within?(Path.t(), Path.t()) :: boolean()
  def within?(path, root) when is_binary(path) and is_binary(root) do
    normalized_path = normalize_for_comparison(path)
    normalized_root = normalize_for_comparison(root)
    normalized_path == normalized_root or String.starts_with?(normalized_path, normalized_root <> "/")
  end

  def within?(_path, _root), do: false

  @doc false
  @spec same_path?(Path.t(), Path.t()) :: boolean()
  def same_path?(left, right) when is_binary(left) and is_binary(right),
    do: normalize_for_comparison(left) == normalize_for_comparison(right)

  def same_path?(_left, _right), do: false

  @doc false
  @spec reparse_point?(Path.t()) :: {:ok, boolean()} | {:error, term()}
  def reparse_point?(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:ok, true}
      {:ok, _stat} -> windows_reparse_point?(path)
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  def reparse_point?(_path), do: {:error, :invalid_path}

  defp valid_path?(path) do
    cond do
      String.trim(path) == "" -> {:error, :empty}
      String.contains?(path, ["\n", "\r", <<0>>]) -> {:error, :invalid_characters}
      true -> :ok
    end
  end

  defp reject_reparse_components(path) do
    path
    |> existing_components()
    |> Enum.reduce_while(:ok, fn component, :ok ->
      case reparse_point?(component) do
        {:ok, false} -> {:cont, :ok}
        {:ok, true} -> {:halt, {:error, {:reparse_point, component}}}
        {:error, reason} -> {:halt, {:error, {:path_unreadable, component, reason}}}
      end
    end)
  end

  defp existing_components(path) do
    path
    |> Path.split()
    |> Enum.scan([], fn segment, acc -> acc ++ [segment] end)
    |> Enum.map(&Path.join/1)
    |> Enum.take_while(&File.exists?/1)
  end

  defp windows_reparse_point?(path) do
    if windows?() do
      WindowsWorkerHost.reparse_point?(path)
    else
      {:ok, false}
    end
  end

  defp normalize_for_comparison(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp windows?, do: match?({:win32, _}, :os.type())
end
