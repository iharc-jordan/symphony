defmodule SymphonyElixir.Managed.Resources do
  @moduledoc """
  Canonical resource references and collision rules for managed assignments.

  Provider adapters may normalize richer provider objects before calling these
  pure helpers. Legacy string resources are accepted only when explicitly
  requested by migration. Repository and path references share an overlap
  boundary when their canonical identities name the same tree, so a path
  spelling cannot bypass a repository-wide write claim.
  """

  @kinds [:repository, :path, :database, :deployment, :other]
  @access [:read, :write]

  @type kind :: :repository | :path | :database | :deployment | :other
  @type access :: :read | :write
  @type resource_ref :: %{
          kind: kind(),
          authority: String.t(),
          identity: String.t(),
          access: access()
        }

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec normalize(term()) :: {:ok, resource_ref()} | {:error, atom(), map()}
  def normalize(resource), do: normalize(resource, [])

  @spec normalize(term(), keyword()) :: {:ok, resource_ref()} | {:error, atom(), map()}

  def normalize(resource, opts) when is_binary(resource) do
    if Keyword.get(opts, :allow_legacy, false) do
      legacy(resource)
    else
      {:error, :resource_reference_required, %{resource: resource}}
    end
  end

  def normalize(resource, _opts) when is_map(resource) do
    kind = resource |> value(:kind) |> normalize_kind()
    authority = resource |> value(:authority) |> text()
    identity = resource |> value(:identity) |> text()
    access = resource |> value(:access) |> normalize_access()

    cond do
      kind == :unknown -> {:error, :invalid_resource_kind, %{kind: value(resource, :kind)}}
      is_nil(authority) -> {:error, :resource_authority_required, %{}}
      is_nil(identity) -> {:error, :resource_identity_required, %{}}
      access == :unknown -> {:error, :invalid_resource_access, %{access: value(resource, :access)}}
      true -> canonical(kind, authority, identity, access)
    end
  end

  def normalize(resource, _opts), do: {:error, :resource_reference_required, %{resource: resource}}

  @spec normalize_all(term()) :: {:ok, [resource_ref()]} | {:error, atom(), map()}
  def normalize_all(resources), do: normalize_all(resources, [])

  @spec normalize_all(term(), keyword()) :: {:ok, [resource_ref()]} | {:error, atom(), map()}

  def normalize_all(resources, opts) when is_list(resources) do
    resources
    |> Enum.reduce_while({:ok, []}, fn resource, {:ok, acc} ->
      case normalize(resource, opts) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, coalesce(refs |> Enum.reverse())}
      error -> error
    end
  end

  def normalize_all(resources, _opts), do: {:error, :resources_must_be_list, %{resources: resources}}

  @spec identity(resource_ref()) :: {kind(), String.t(), String.t()}
  def identity(%{kind: kind, authority: authority, identity: identity}), do: {kind, authority, identity}

  @spec writable?(resource_ref()) :: boolean()
  def writable?(%{access: :write}), do: true
  def writable?(_resource), do: false

  @spec overlaps?(resource_ref(), resource_ref()) :: boolean()
  def overlaps?(left, right) when is_map(left) and is_map(right) do
    left.authority == right.authority and identities_overlap?(left.kind, left.identity, right.kind, right.identity)
  end

  def overlaps?(_left, _right), do: false

  @spec conflicts?(resource_ref(), resource_ref()) :: boolean()
  def conflicts?(left, right) when is_map(left) and is_map(right) do
    overlaps?(left, right) and (writable?(left) or writable?(right))
  end

  def conflicts?(_left, _right), do: false

  @spec conflict(resource_ref(), [resource_ref()]) :: {:ok, :free} | {:error, atom(), map()}
  def conflict(candidate, existing) when is_map(candidate) and is_list(existing) do
    case Enum.find(existing, &conflicts?(candidate, &1)) do
      nil -> {:ok, :free}
      conflicting -> {:error, :resource_conflict, %{resource: candidate, conflicting_resource: conflicting}}
    end
  end

  def conflict(_candidate, _existing), do: {:error, :resources_invalid, %{}}

  @spec legacy_identity(String.t()) :: String.t()
  def legacy_identity(resource) when is_binary(resource) do
    resource |> String.trim() |> String.downcase()
  end

  defp legacy(resource) do
    identity = legacy_identity(resource)

    if identity == "" do
      {:error, :resource_identity_required, %{}}
    else
      {:ok, %{kind: :other, authority: "legacy", identity: identity, access: :write}}
    end
  end

  defp canonical(:repository, authority, identity, access) do
    authority = normalize_authority(authority)
    identity = normalize_repository(identity)

    if authority == "" or identity == "" do
      {:error, :resource_identity_required, %{}}
    else
      {:ok, %{kind: :repository, authority: authority, identity: identity, access: access}}
    end
  end

  defp canonical(:path, authority, identity, access) do
    identity = normalize_path(identity)

    if identity == "" do
      {:error, :resource_identity_required, %{}}
    else
      {:ok, %{kind: :path, authority: normalize_authority(authority), identity: identity, access: access}}
    end
  end

  defp canonical(kind, authority, identity, access) do
    {:ok, %{kind: kind, authority: normalize_authority(authority), identity: normalize_opaque(identity), access: access}}
  end

  defp identities_overlap?(left_kind, left, right_kind, right)
       when left_kind in [:repository, :path] and right_kind in [:repository, :path] do
    left == right or String.starts_with?(left, right <> "/") or String.starts_with?(right, left <> "/")
  end

  defp identities_overlap?(kind, left, kind, right), do: identities_overlap_same_kind?(kind, left, right)
  defp identities_overlap?(_left_kind, _left, _right_kind, _right), do: false

  defp identities_overlap_same_kind?(:path, left, right) do
    left == right or String.starts_with?(left, right <> "/") or String.starts_with?(right, left <> "/")
  end

  defp identities_overlap_same_kind?(_kind, left, right), do: left == right

  defp normalize_kind(value) when value in @kinds, do: value

  defp normalize_kind(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "repository" -> :repository
      "repo" -> :repository
      "path" -> :path
      "database" -> :database
      "db" -> :database
      "deployment" -> :deployment
      "deploy" -> :deployment
      "other" -> :other
      _ -> :unknown
    end
  end

  defp normalize_kind(_value), do: :unknown

  defp normalize_access(value) when value in @access, do: value

  defp normalize_access(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "read" -> :read
      "write" -> :write
      _ -> :unknown
    end
  end

  defp normalize_access(_value), do: :unknown

  defp normalize_authority(value), do: value |> String.trim() |> String.downcase()

  defp normalize_repository(identity) do
    identity
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
    |> String.replace_prefix("git@", "")
    |> String.replace_prefix("github:", "")
    |> String.replace_prefix("github.com:", "")
    |> String.replace_prefix("github.com/", "")
    |> String.replace_suffix(".git", "")
    |> String.trim("/")
  end

  defp normalize_path(identity) do
    identity
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.replace(~r{/+}, "/")
    |> String.split("/", trim: true)
    |> reduce_path_segments([])
    |> Enum.reverse()
    |> Enum.join("/")
  end

  defp reduce_path_segments([], acc), do: acc
  defp reduce_path_segments(["." | rest], acc), do: reduce_path_segments(rest, acc)

  defp reduce_path_segments([".." | rest], [_segment | acc]),
    do: reduce_path_segments(rest, acc)

  defp reduce_path_segments([".." | rest], []), do: reduce_path_segments(rest, [])
  defp reduce_path_segments([segment | rest], acc), do: reduce_path_segments(rest, [segment | acc])
  defp normalize_opaque(identity), do: identity |> String.trim() |> String.downcase()

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp text(_value), do: nil

  defp coalesce(resources) do
    {by_identity, order} =
      Enum.reduce(resources, {%{}, []}, fn resource, {by_identity, order} ->
        key = identity(resource)

        case Map.fetch(by_identity, key) do
          :error ->
            {Map.put(by_identity, key, resource), order ++ [key]}

          {:ok, existing} ->
            access = if writable?(existing) or writable?(resource), do: :write, else: :read
            {Map.put(by_identity, key, %{existing | access: access}), order}
        end
      end)

    Enum.map(order, &Map.fetch!(by_identity, &1))
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
