defmodule SymphonyElixir.HookContext do
  @moduledoc """
  Builds the bounded issue context exposed to workspace hooks.

  Hooks receive only stable issue identity and a provider-native reference. The
  native reference contract is non-secret provider identity/location metadata
  represented with JSON values. Forbidden payload, issue-content, executable,
  authentication, and credential keys cause encoding to fail.
  """

  @env_name "SYMPHONY_ISSUE_CONTEXT"
  @max_bytes 16 * 1024

  @type issue_like :: map() | String.t() | nil
  @type encode_error ::
          :invalid_issue_context
          | {:invalid_native_ref, term()}
          | {:too_large, non_neg_integer(), pos_integer()}

  @forbidden_key ~r/(?:^|[_-])(?:api[_-]?key|auth|authorization|access[_-]?token|refresh[_-]?token|bearer[_-]?token|client[_-]?secret|credential(?:s)?|password|passwd|private[_-]?key(?:[_-]?file)?|secret|token|cookie|body|description|title|command(?:s)?|executable|payload|user(?:[_-]?info)?|author)(?:$|[_-])/i

  @doc """
  Returns the environment variable name used for hook context.
  """
  @spec env_name() :: String.t()
  def env_name, do: @env_name

  @doc """
  Returns the maximum serialized context size in bytes.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Encodes the safe hook context for an issue, identifier, or missing issue.

  Missing issue context is represented explicitly as JSON `null` values. An
  invalid native reference or oversized context is rejected so hooks never run
  with silently truncated or unsafe data.
  """
  @spec encode(issue_like()) :: {:ok, String.t()} | {:error, encode_error()}
  def encode(issue_or_identifier) do
    case sanitize_native_ref(issue_native_ref(issue_or_identifier)) do
      {:ok, native_ref} ->
        context = %{
          "id" => sanitize_json(issue_id(issue_or_identifier)),
          "identifier" => sanitize_json(issue_identifier(issue_or_identifier)),
          "native_ref" => native_ref
        }

        encode_context(context)

      {:error, reason} ->
        {:error, {:invalid_native_ref, reason}}
    end
  end

  defp encode_context(context) do
    case Jason.encode(context) do
      {:ok, encoded} when byte_size(encoded) <= @max_bytes ->
        {:ok, encoded}

      {:ok, encoded} ->
        {:error, {:too_large, byte_size(encoded), @max_bytes}}

      {:error, _reason} ->
        {:error, :invalid_issue_context}
    end
  end

  defp issue_id(%{id: id}), do: id
  defp issue_id(%{"id" => id}), do: id
  defp issue_id(_issue_or_identifier), do: nil

  defp issue_identifier(%{identifier: identifier}), do: identifier
  defp issue_identifier(%{"identifier" => identifier}), do: identifier
  defp issue_identifier(identifier) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue_or_identifier), do: nil

  defp issue_native_ref(%{native_ref: native_ref}), do: native_ref
  defp issue_native_ref(%{"native_ref" => native_ref}), do: native_ref
  defp issue_native_ref(_issue_or_identifier), do: nil

  defp sanitize_json(nil), do: nil
  defp sanitize_json(value) when is_binary(value), do: value
  defp sanitize_json(value) when is_boolean(value), do: value
  defp sanitize_json(value) when is_integer(value), do: value
  defp sanitize_json(value) when is_float(value), do: value
  defp sanitize_json(_value), do: nil

  defp sanitize_native_ref(nil), do: {:ok, nil}
  defp sanitize_native_ref(value) when is_binary(value), do: {:ok, value}
  defp sanitize_native_ref(value) when is_boolean(value), do: {:ok, value}
  defp sanitize_native_ref(value) when is_integer(value), do: {:ok, value}
  defp sanitize_native_ref(value) when is_float(value), do: {:ok, value}

  defp sanitize_native_ref(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn child, {:ok, acc} ->
      case sanitize_native_ref(child) do
        {:ok, sanitized_child} -> {:cont, {:ok, [sanitized_child | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_sanitized_list()
  end

  defp sanitize_native_ref(value) when is_map(value) do
    if struct?(value) do
      {:error, :non_json_value}
    else
      sanitize_native_ref_map(value)
    end
  end

  defp sanitize_native_ref(_value), do: {:error, :non_json_value}

  defp sanitize_native_ref_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, &sanitize_native_ref_map_entry/2)
  end

  defp sanitize_native_ref_map_entry({key, child}, {:ok, acc}) do
    case json_key(key) do
      {:ok, string_key} ->
        sanitize_native_ref_map_value(string_key, child, acc)

      :error ->
        {:halt, {:error, :non_json_key}}
    end
  end

  defp sanitize_native_ref_map_value(string_key, child, acc) do
    if forbidden_key?(string_key) do
      {:halt, {:error, {:forbidden_key, string_key}}}
    else
      case sanitize_native_ref(child) do
        {:ok, sanitized_child} ->
          {:cont, {:ok, Map.put(acc, string_key, sanitized_child)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end
  end

  defp reverse_sanitized_list({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_sanitized_list(error), do: error

  defp json_key(key) when is_binary(key), do: {:ok, key}
  defp json_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp json_key(key) when is_integer(key), do: {:ok, Integer.to_string(key)}
  defp json_key(key) when is_float(key), do: {:ok, Float.to_string(key)}
  defp json_key(_key), do: :error

  defp forbidden_key?(key), do: Regex.match?(@forbidden_key, key)

  defp struct?(value) do
    Map.has_key?(value, :__struct__) or Map.has_key?(value, "__struct__")
  end
end
