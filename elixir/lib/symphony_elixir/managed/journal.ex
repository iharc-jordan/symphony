defmodule SymphonyElixir.Managed.Journal do
  @moduledoc """
  Small durable journal for managed orchestration state and events.

  The journal stores versioned operational terms only. The orchestrator owns
  the handle and is the only process that appends records. A checkpoint holds
  the latest verified state; the disk log is the write-ahead record used across
  an interrupted checkpoint or when migrating the legacy append-only journal.
  """

  @version 1
  @checkpoint_checksum :sha256
  @type handle :: %{name: atom(), path: Path.t(), checkpoint_path: Path.t()}

  @spec open(Path.t(), keyword()) :: {:ok, handle(), map()} | {:error, term()}
  def open(path, opts \\ []) when is_binary(path) do
    expanded = Path.expand(path)
    checkpoint_path = checkpoint_path(expanded)
    name = Keyword.get(opts, :name, journal_name(expanded))

    with :ok <- ensure_parent(expanded),
         {:ok, checkpoint} <- load_checkpoint(checkpoint_path) do
      open_and_recover(name, expanded, checkpoint_path, checkpoint)
    end
  end

  @spec append(handle(), map()) :: :ok | {:error, term()}
  def append(%{name: name} = handle, state) when is_map(state) do
    record = state_record(state)

    with :ok <- replace_wal(name, record),
         {:ok, checkpoint_path} <- handle_checkpoint_path(handle),
         :ok <- persist_checkpoint(checkpoint_path, record) do
      truncate_wal(name)
    end
  end

  @spec close(handle()) :: :ok
  def close(%{name: name}) do
    _ = :disk_log.close(name)
    :ok
  end

  @spec version() :: pos_integer()
  def version, do: @version

  defp open_and_recover(name, path, checkpoint_path, checkpoint) do
    case open_log(name, path, checkpoint) do
      {:ok, _name} ->
        case recover(name, checkpoint_path, checkpoint) do
          {:ok, state} ->
            {:ok, %{name: name, path: path, checkpoint_path: checkpoint_path}, state}

          {:error, _reason} = error ->
            _ = :disk_log.close(name)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp recover(name, checkpoint_path, :missing) do
    with {:ok, state, _record_count} <- load_latest(name, %{}),
         :ok <- persist_checkpoint(checkpoint_path, state_record(state)),
         :ok <- truncate_wal(name) do
      {:ok, state}
    end
  end

  defp recover(name, checkpoint_path, {:present, checkpoint_state}) do
    with {:ok, state, record_count} <- load_latest(name, checkpoint_state),
         :ok <- compact_recovered_wal(name, checkpoint_path, state, record_count) do
      {:ok, state}
    end
  end

  defp compact_recovered_wal(_name, _checkpoint_path, _state, 0), do: :ok

  defp compact_recovered_wal(name, checkpoint_path, state, _record_count) do
    with :ok <- persist_checkpoint(checkpoint_path, state_record(state)) do
      truncate_wal(name)
    end
  end

  defp open_log(name, path, checkpoint) do
    case :disk_log.open(name: name, file: String.to_charlist(path), type: :halt) do
      {:ok, ^name} ->
        {:ok, name}

      {:repaired, ^name, {:recovered, _recovered}, {:badbytes, 0}} ->
        {:ok, name}

      {:repaired, ^name, {:recovered, _recovered}, {:badbytes, _bad_bytes}}
      when checkpoint != :missing ->
        {:ok, name}

      {:repaired, ^name, {:recovered, _recovered}, {:badbytes, bad_bytes}} ->
        _ = :disk_log.close(name)
        {:error, {:managed_journal_corrupt, bad_bytes}}

      {:error, reason} ->
        {:error, {:managed_journal_open_failed, reason}}
    end
  end

  defp load_latest(name, initial_state) do
    case read_records(name, :start, initial_state, 0) do
      {:ok, state, record_count} ->
        {:ok, state, record_count}

      {:error, reason} ->
        {:error, {:managed_journal_read_failed, reason}}
    end
  end

  defp read_records(name, continuation, latest, record_count) do
    case :disk_log.chunk(name, continuation) do
      :eof ->
        {:ok, latest, record_count}

      {next, records} when is_list(records) ->
        continue_records(name, next, records, latest, record_count)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_records(name, next, records, latest, record_count) do
    case latest_record(records, latest) do
      {:ok, state} -> read_records(name, next, state, record_count + length(records))
      {:error, reason} -> {:error, reason}
    end
  end

  defp latest_record(records, latest) do
    Enum.reduce_while(records, {:ok, latest}, fn record, {:ok, _acc} ->
      case record_state(record) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp state_record(state), do: %{version: @version, kind: :state, state: state}

  defp record_state(%{version: @version, kind: :state, state: state}) when is_map(state),
    do: {:ok, state}

  defp record_state(%{version: version}),
    do: {:error, {:managed_journal_schema_mismatch, version}}

  defp record_state(_record), do: {:error, :managed_journal_malformed_record}

  defp load_checkpoint(path) do
    case File.read(path) do
      {:ok, binary} ->
        case decode_checkpoint(binary) do
          {:ok, record} ->
            {:ok, {:present, record.state}}

          {:error, reason} ->
            {:error, {:managed_journal_checkpoint_invalid, reason}}
        end

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, {:managed_journal_checkpoint_read_failed, reason}}
    end
  end

  defp persist_checkpoint(path, record) do
    temporary_path = temporary_checkpoint_path(path)
    binary = encode_checkpoint(record)

    try do
      with :ok <- write_and_sync(temporary_path, binary),
           :ok <- rename_checkpoint(temporary_path, path),
           :ok <- sync_parent_directory(path),
           {:ok, persisted_record} <- read_checkpoint_record(path) do
        exact_checkpoint(record, persisted_record)
      end
    after
      _ = File.rm(temporary_path)
    end
  end

  defp write_and_sync(path, binary) do
    result =
      File.open(path, [:write, :binary, :exclusive], fn file ->
        with :ok <- IO.binwrite(file, binary) do
          :file.sync(file)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, {:managed_journal_checkpoint_write_failed, reason}}
      {:error, reason} -> {:error, {:managed_journal_checkpoint_write_failed, reason}}
    end
  end

  defp rename_checkpoint(source, destination) do
    case File.rename(source, destination) do
      :ok -> :ok
      {:error, reason} -> {:error, {:managed_journal_checkpoint_rename_failed, reason}}
    end
  end

  defp sync_parent_directory(path) do
    directory = path |> Path.dirname() |> String.to_charlist()

    case :file.open(directory, [:read, :raw, :directory]) do
      {:ok, file} ->
        result = :file.sync(file)
        _ = :file.close(file)

        case result do
          :ok -> :ok
          {:error, reason} -> {:error, {:managed_journal_checkpoint_directory_sync_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:managed_journal_checkpoint_directory_sync_failed, reason}}
    end
  end

  defp read_checkpoint_record(path) do
    case File.read(path) do
      {:ok, binary} ->
        case decode_checkpoint(binary) do
          {:ok, record} -> {:ok, record}
          {:error, reason} -> {:error, {:managed_journal_checkpoint_verify_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:managed_journal_checkpoint_verify_failed, reason}}
    end
  end

  defp decode_checkpoint(binary) do
    with {:ok, envelope} <- decode_external_term(binary, :managed_journal_checkpoint),
         {:ok, payload, checksum} <- checkpoint_payload(envelope),
         :ok <- verify_checkpoint_checksum(payload, checksum),
         {:ok, record} <- decode_external_term(payload, :managed_journal_checkpoint_payload),
         {:ok, _state} <- record_state(record) do
      {:ok, record}
    end
  end

  defp encode_checkpoint(record) do
    payload = :erlang.term_to_binary(record)

    :erlang.term_to_binary(%{
      version: @version,
      kind: :checkpoint,
      checksum_algorithm: @checkpoint_checksum,
      checksum: :crypto.hash(@checkpoint_checksum, payload),
      payload: payload
    })
  end

  defp checkpoint_payload(%{
         version: @version,
         kind: :checkpoint,
         checksum_algorithm: @checkpoint_checksum,
         checksum: checksum,
         payload: payload
       })
       when is_binary(checksum) and byte_size(checksum) == 32 and is_binary(payload),
       do: {:ok, payload, checksum}

  defp checkpoint_payload(%{version: version}),
    do: {:error, {:managed_journal_schema_mismatch, version}}

  defp checkpoint_payload(_envelope), do: {:error, :managed_journal_checkpoint_malformed}

  defp verify_checkpoint_checksum(payload, checksum) do
    if :crypto.hash(@checkpoint_checksum, payload) === checksum do
      :ok
    else
      {:error, :managed_journal_checkpoint_checksum_mismatch}
    end
  end

  defp decode_external_term(binary, prefix) do
    case :erlang.binary_to_term(binary, [:safe, :used]) do
      {term, used} when used == byte_size(binary) -> {:ok, term}
      {_term, _used} -> {:error, external_term_error(prefix, :trailing_bytes)}
    end
  rescue
    ArgumentError -> {:error, external_term_error(prefix, :corrupt)}
  catch
    :error, :badarg -> {:error, external_term_error(prefix, :corrupt)}
  end

  defp external_term_error(:managed_journal_checkpoint, :trailing_bytes),
    do: :managed_journal_checkpoint_trailing_bytes

  defp external_term_error(:managed_journal_checkpoint, :corrupt),
    do: :managed_journal_checkpoint_corrupt

  defp external_term_error(:managed_journal_checkpoint_payload, :trailing_bytes),
    do: :managed_journal_checkpoint_payload_trailing_bytes

  defp external_term_error(:managed_journal_checkpoint_payload, :corrupt),
    do: :managed_journal_checkpoint_payload_corrupt

  defp exact_checkpoint(expected, actual) when expected === actual, do: :ok

  defp exact_checkpoint(_expected, _actual),
    do: {:error, {:managed_journal_checkpoint_verify_failed, :state_mismatch}}

  defp log(name, record) do
    case :disk_log.log(name, record) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_wal(name, record) do
    with :ok <- clear_wal(name),
         :ok <- log(name, record) do
      sync(name)
    end
  end

  defp clear_wal(name) do
    case :disk_log.truncate(name) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp truncate_wal(name) do
    case :disk_log.truncate(name) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:managed_journal_truncate_failed, reason}}
    end
  end

  defp sync(name), do: :disk_log.sync(name)

  defp handle_checkpoint_path(%{checkpoint_path: path}) when is_binary(path),
    do: {:ok, path}

  defp handle_checkpoint_path(%{path: path}) when is_binary(path),
    do: {:ok, checkpoint_path(path)}

  defp handle_checkpoint_path(_handle),
    do: {:error, :managed_journal_checkpoint_path_missing}

  defp checkpoint_path(path), do: path <> ".checkpoint"

  defp temporary_checkpoint_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{path}.tmp-#{suffix}"
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
