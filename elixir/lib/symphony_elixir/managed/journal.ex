defmodule SymphonyElixir.Managed.Journal do
  @moduledoc """
  Small durable journal for managed orchestration state and events.

  The journal stores versioned operational terms only. The orchestrator owns
  the handle and is the only process that appends records.
  """

  @version 1
  @type handle :: %{name: atom(), path: Path.t()}

  @spec open(Path.t(), keyword()) :: {:ok, handle(), map()} | {:error, term()}
  def open(path, opts \\ []) when is_binary(path) do
    expanded = Path.expand(path)
    name = Keyword.get(opts, :name, journal_name(expanded))

    with :ok <- ensure_parent(expanded),
         {:ok, _} <- open_log(name, expanded),
         {:ok, state} <- load_latest(name) do
      {:ok, %{name: name, path: expanded}, state}
    else
      {:error, reason} ->
        _ = :disk_log.close(name)
        {:error, reason}
    end
  end

  @spec append(handle(), map()) :: :ok | {:error, term()}
  def append(%{name: name}, state) when is_map(state) do
    record = %{version: @version, kind: :state, state: state}

    case :disk_log.log(name, record) do
      :ok -> sync(name)
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @spec close(handle()) :: :ok
  def close(%{name: name}) do
    _ = :disk_log.close(name)
    :ok
  end

  @spec version() :: pos_integer()
  def version, do: @version

  defp open_log(name, path) do
    case :disk_log.open(name: name, file: String.to_charlist(path), type: :halt) do
      {:ok, ^name} ->
        {:ok, name}

      {:repaired, ^name, _recovered, 0} ->
        {:ok, name}

      {:repaired, ^name, _recovered, bad_bytes} ->
        {:error, {:managed_journal_corrupt, bad_bytes}}

      {:error, reason} ->
        {:error, {:managed_journal_open_failed, reason}}

      other ->
        {:error, {:managed_journal_open_failed, other}}
    end
  end

  defp load_latest(name) do
    case read_records(name, :start, %{}) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:managed_journal_read_failed, reason}}
    end
  end

  defp read_records(name, continuation, latest) do
    case :disk_log.chunk(name, continuation) do
      :eof ->
        {:ok, latest}

      {next, records} when is_list(records) ->
        case latest_record(records, latest) do
          {:ok, state} -> read_records(name, next, state)
          {:error, reason} -> {:error, reason}
        end

      {next, records, bad_bytes} when is_list(records) and bad_bytes == 0 ->
        case latest_record(records, latest) do
          {:ok, state} -> read_records(name, next, state)
          {:error, reason} -> {:error, reason}
        end

      {_next, _records, bad_bytes} ->
        {:error, {:managed_journal_corrupt, bad_bytes}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp latest_record(records, latest) do
    Enum.reduce_while(records, {:ok, latest}, fn record, {:ok, _acc} ->
      case record do
        %{version: @version, kind: :state, state: state} when is_map(state) ->
          {:cont, {:ok, state}}

        %{version: version} ->
          {:halt, {:error, {:managed_journal_schema_mismatch, version}}}

        _ ->
          {:halt, {:error, :managed_journal_malformed_record}}
      end
    end)
  end

  defp sync(name) do
    case :disk_log.sync(name) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp ensure_parent(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:managed_journal_parent_failed, reason}}
    end
  end

  defp journal_name(path) do
    String.to_atom("symphony_managed_journal_#{:erlang.phash2(path)}")
  end
end
