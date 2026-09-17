defmodule SymphonyElixir.Managed.Usage do
  @moduledoc """
  Pure managed token-accounting helpers.

  Codex reports cumulative counters for a source thread. The durable source
  watermark is deliberately separate from assignment lifetime totals, so a
  resumed thread is charged only for its new counter delta.
  """

  @type usage :: map()
  @type source :: map()

  @spec new_aggregate(keyword()) :: usage()
  def new_aggregate(opts \\ []) do
    %{
      baseline_tokens: nonnegative(Keyword.get(opts, :baseline_tokens, 0)),
      cumulative_tokens: nonnegative(Keyword.get(opts, :cumulative_tokens, 0)),
      inflight_tokens: 0,
      overshoot_tokens: 0,
      cap_reached: false,
      accounting_status: :known,
      historical_raw_tokens: %{}
    }
  end

  @spec normalize_aggregate(term()) :: usage()
  def normalize_aggregate(usage) when is_map(usage) do
    status = accounting_status(usage)

    normalized = %{
      baseline_tokens: if(status == :known, do: nonnegative(usage[:baseline_tokens]), else: 0),
      cumulative_tokens: if(status == :known, do: nonnegative(usage[:cumulative_tokens]), else: 0),
      inflight_tokens: if(status == :known, do: nonnegative(usage[:inflight_tokens]), else: 0),
      overshoot_tokens: if(status == :known, do: nonnegative(usage[:overshoot_tokens]), else: 0),
      cap_reached: status == :known and usage[:cap_reached] == true,
      accounting_status: status,
      historical_raw_tokens: historical_raw_tokens(usage, status)
    }

    Map.merge(usage, normalized)
  end

  def normalize_aggregate(_usage), do: new_aggregate()

  @spec accounting_status(term()) :: :known | :unavailable
  def accounting_status(usage) when is_map(usage) do
    case usage[:accounting_status] do
      :known -> :known
      :unavailable -> :unavailable
      _ -> if(legacy_usage_present?(usage), do: :unavailable, else: :known)
    end
  end

  def accounting_status(_usage), do: :known

  @spec add_aggregate_delta(usage(), non_neg_integer(), integer() | nil) :: usage()
  def add_aggregate_delta(usage, total_delta, limit)
      when is_map(usage) and is_integer(total_delta) and total_delta >= 0 do
    usage = normalize_aggregate(usage)

    if usage.accounting_status == :known do
      cumulative = usage.cumulative_tokens + total_delta
      cap_reached = is_integer(limit) and limit > 0 and cumulative >= limit

      %{
        usage
        | cumulative_tokens: cumulative,
          inflight_tokens: usage.inflight_tokens + total_delta,
          overshoot_tokens: if(cap_reached, do: max(cumulative - limit, 0), else: 0),
          cap_reached: cap_reached
      }
    else
      usage
    end
  end

  def add_aggregate_delta(usage, _total_delta, _limit), do: normalize_aggregate(usage)

  @spec complete_aggregate_attempt(usage(), non_neg_integer(), integer() | nil) :: usage()
  def complete_aggregate_attempt(usage, persisted_inflight, limit)
      when is_map(usage) and is_integer(persisted_inflight) and persisted_inflight >= 0 do
    usage = normalize_aggregate(usage)

    if usage.accounting_status == :known do
      usage
      |> Map.put(:inflight_tokens, max(usage.inflight_tokens - persisted_inflight, 0))
      |> refresh_cap(limit)
    else
      usage
    end
  end

  def complete_aggregate_attempt(usage, _persisted_inflight, _limit), do: normalize_aggregate(usage)

  @spec clear_inflight(term()) :: usage()
  def clear_inflight(usage) when is_map(usage) do
    usage = normalize_aggregate(usage)
    %{usage | inflight_tokens: 0}
  end

  def clear_inflight(_usage), do: new_aggregate()

  @spec source_for(map(), String.t()) :: source()
  def source_for(assignment, thread_id) when is_map(assignment) and is_binary(thread_id) do
    case assignment[:usage_source] do
      %{thread_id: ^thread_id} = source ->
        normalize_source(source, thread_id)

      _ ->
        if assignment[:thread_id] == thread_id do
          legacy_source(assignment[:usage], thread_id)
        else
          new_source(thread_id)
        end
    end
  end

  def source_for(_assignment, thread_id) when is_binary(thread_id), do: new_source(thread_id)
  def source_for(_assignment, _thread_id), do: new_source(nil)

  @spec start_source(map(), String.t(), String.t()) :: map()
  def start_source(assignment, thread_id, attempt_id)
      when is_map(assignment) and is_binary(thread_id) and is_binary(attempt_id) do
    # A journal written before durable source watermarks cannot prove whether
    # its assignment lifetime total is complete. Keep its raw counters so a
    # resumed thread does not replay them, but never promote that legacy value
    # to authoritative accounting merely by starting a source.
    assignment = normalize_assignment(assignment)

    source =
      assignment
      |> source_for(thread_id)
      |> Map.merge(%{
        active_attempt_id: attempt_id,
        inflight_input_tokens: 0,
        inflight_output_tokens: 0,
        inflight_tokens: 0,
        inflight_cached_input_tokens: nil
      })

    Map.put(assignment, :usage_source, source)
  end

  def start_source(assignment, _thread_id, _attempt_id), do: assignment

  @spec source_raw(term()) :: usage()
  def source_raw(source) when is_map(source) do
    %{
      input_tokens: nonnegative(source[:input_tokens]),
      output_tokens: nonnegative(source[:output_tokens]),
      total_tokens: nonnegative(source[:total_tokens]),
      cached_input_tokens: optional_nonnegative(source[:cached_input_tokens])
    }
  end

  def source_raw(_source), do: zero_delta()

  @spec record_delta(map(), String.t(), String.t(), usage(), usage()) :: map()
  def record_delta(assignment, thread_id, attempt_id, raw, delta)
      when is_map(assignment) and is_binary(thread_id) and is_binary(attempt_id) and is_map(raw) and is_map(delta) do
    source = source_for(assignment, thread_id)

    delta =
      if source[:active_attempt_id] in [nil, attempt_id] do
        normalize_delta(delta)
      else
        zero_delta()
      end

    source =
      source
      |> put_raw_watermarks(raw)
      |> Map.merge(%{
        active_attempt_id: attempt_id,
        inflight_input_tokens: nonnegative(source[:inflight_input_tokens]) + delta.input_tokens,
        inflight_output_tokens: nonnegative(source[:inflight_output_tokens]) + delta.output_tokens,
        inflight_tokens: nonnegative(source[:inflight_tokens]) + delta.total_tokens,
        inflight_cached_input_tokens: add_optional(source[:inflight_cached_input_tokens], delta[:cached_input_tokens])
      })

    usage =
      assignment
      |> lifetime_usage()
      |> add_lifetime_delta(delta)

    assignment
    |> Map.put(:usage_source, source)
    |> Map.put(:usage, usage)
  end

  def record_delta(assignment, _thread_id, _attempt_id, _raw, _delta), do: assignment

  @spec complete_attempt(map(), String.t() | nil, String.t(), usage(), non_neg_integer()) ::
          {map(), usage(), non_neg_integer()}
  def complete_attempt(assignment, thread_id, attempt_id, raw, seconds_running)
      when is_map(assignment) and is_binary(attempt_id) and is_map(raw) and
             is_integer(seconds_running) and seconds_running >= 0 do
    source =
      if is_binary(thread_id) do
        source_for(assignment, thread_id)
      else
        assignment[:usage_source] || new_source(nil)
      end

    if source[:completed_attempt_id] == attempt_id do
      {assignment, zero_delta(), 0}
    else
      delta = raw_delta(source_raw(source), raw)
      persisted_inflight = nonnegative(source[:inflight_tokens])
      usage = assignment |> lifetime_usage() |> add_lifetime_delta(delta) |> add_completed_seconds(seconds_running)

      source =
        source
        |> put_raw_watermarks(raw)
        |> Map.merge(%{
          active_attempt_id: nil,
          completed_attempt_id: attempt_id,
          inflight_input_tokens: 0,
          inflight_output_tokens: 0,
          inflight_tokens: 0,
          inflight_cached_input_tokens: nil
        })

      {assignment |> Map.put(:usage, usage) |> Map.put(:usage_source, source), delta, persisted_inflight}
    end
  end

  def complete_attempt(assignment, _thread_id, _attempt_id, _raw, _seconds_running), do: {assignment, zero_delta(), 0}

  @spec normalize_assignment(term()) :: term()
  def normalize_assignment(assignment) when is_map(assignment) do
    if legacy_lifetime_usage?(assignment) do
      update_in(assignment, [:usage], &Map.merge(&1, %{accounting_status: :unavailable, runtime_complete: false}))
    else
      assignment
    end
  end

  def normalize_assignment(assignment), do: assignment

  @spec clear_assignment_inflight(map()) :: map()
  def clear_assignment_inflight(assignment) when is_map(assignment) do
    assignment = normalize_assignment(assignment)

    case assignment[:usage_source] do
      source when is_map(source) ->
        Map.put(
          assignment,
          :usage_source,
          Map.merge(source, %{active_attempt_id: nil, inflight_input_tokens: 0, inflight_output_tokens: 0, inflight_tokens: 0, inflight_cached_input_tokens: nil})
        )

      _ ->
        assignment
    end
  end

  def clear_assignment_inflight(assignment), do: assignment

  @spec raw_delta(term(), term()) :: usage()
  def raw_delta(previous, raw) when is_map(previous) and is_map(raw) do
    %{
      input_tokens: max(nonnegative(raw[:input_tokens]) - nonnegative(previous[:input_tokens]), 0),
      output_tokens: max(nonnegative(raw[:output_tokens]) - nonnegative(previous[:output_tokens]), 0),
      total_tokens: max(nonnegative(raw[:total_tokens]) - nonnegative(previous[:total_tokens]), 0),
      cached_input_tokens: optional_delta(previous[:cached_input_tokens], raw[:cached_input_tokens])
    }
  end

  def raw_delta(_previous, _raw), do: zero_delta()

  defp lifetime_usage(assignment) do
    usage = Map.get(assignment, :usage, %{})

    legacy? =
      is_map(usage) and map_size(usage) > 0 and
        not Map.has_key?(assignment, :usage_source) and
        usage[:accounting_status] not in [:known, :unavailable]

    accounting_status =
      cond do
        usage[:accounting_status] in [:known, :unavailable] -> usage[:accounting_status]
        legacy? -> :unavailable
        true -> :known
      end

    %{
      input_tokens: nonnegative(usage[:input_tokens]),
      output_tokens: nonnegative(usage[:output_tokens]),
      total_tokens: nonnegative(usage[:total_tokens]),
      cached_input_tokens: optional_nonnegative(usage[:cached_input_tokens]),
      seconds_running: nonnegative(usage[:seconds_running]),
      telemetry_complete: usage[:telemetry_complete] == true,
      runtime_complete: accounting_status == :known and usage[:runtime_complete] != false,
      accounting_status: accounting_status
    }
  end

  defp add_lifetime_delta(usage, delta) do
    %{
      usage
      | input_tokens: usage.input_tokens + nonnegative(delta[:input_tokens]),
        output_tokens: usage.output_tokens + nonnegative(delta[:output_tokens]),
        total_tokens: usage.total_tokens + nonnegative(delta[:total_tokens]),
        cached_input_tokens: add_optional(usage[:cached_input_tokens], delta[:cached_input_tokens])
    }
  end

  defp add_completed_seconds(usage, seconds_running) do
    %{usage | seconds_running: usage.seconds_running + seconds_running}
  end

  defp put_raw_watermarks(source, raw) do
    %{
      source
      | input_tokens: max(nonnegative(source[:input_tokens]), nonnegative(raw[:input_tokens])),
        output_tokens: max(nonnegative(source[:output_tokens]), nonnegative(raw[:output_tokens])),
        total_tokens: max(nonnegative(source[:total_tokens]), nonnegative(raw[:total_tokens])),
        cached_input_tokens: max_optional(source[:cached_input_tokens], raw[:cached_input_tokens])
    }
  end

  defp normalize_source(source, thread_id) do
    %{
      thread_id: thread_id,
      input_tokens: nonnegative(source[:input_tokens]),
      output_tokens: nonnegative(source[:output_tokens]),
      total_tokens: nonnegative(source[:total_tokens]),
      cached_input_tokens: optional_nonnegative(source[:cached_input_tokens]),
      active_attempt_id: source[:active_attempt_id],
      completed_attempt_id: source[:completed_attempt_id],
      inflight_input_tokens: nonnegative(source[:inflight_input_tokens]),
      inflight_output_tokens: nonnegative(source[:inflight_output_tokens]),
      inflight_tokens: nonnegative(source[:inflight_tokens]),
      inflight_cached_input_tokens: optional_nonnegative(source[:inflight_cached_input_tokens])
    }
  end

  defp legacy_source(usage, thread_id) when is_map(usage) do
    %{
      thread_id: thread_id,
      input_tokens: nonnegative(usage[:input_tokens]),
      output_tokens: nonnegative(usage[:output_tokens]),
      total_tokens: nonnegative(usage[:total_tokens]),
      cached_input_tokens: optional_nonnegative(usage[:cached_input_tokens]),
      active_attempt_id: nil,
      completed_attempt_id: nil,
      inflight_input_tokens: 0,
      inflight_output_tokens: 0,
      inflight_tokens: 0,
      inflight_cached_input_tokens: nil
    }
  end

  defp legacy_source(_usage, thread_id), do: new_source(thread_id)

  defp new_source(thread_id) do
    %{
      thread_id: thread_id,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cached_input_tokens: nil,
      active_attempt_id: nil,
      completed_attempt_id: nil,
      inflight_input_tokens: 0,
      inflight_output_tokens: 0,
      inflight_tokens: 0,
      inflight_cached_input_tokens: nil
    }
  end

  defp refresh_cap(usage, limit) do
    if is_integer(limit) and limit > 0 do
      cumulative = usage.cumulative_tokens
      %{usage | overshoot_tokens: max(cumulative - limit, 0), cap_reached: cumulative >= limit}
    else
      usage
    end
  end

  defp historical_raw_tokens(usage, :known) do
    case usage[:historical_raw_tokens] do
      values when is_map(values) -> values
      _ -> %{}
    end
  end

  defp historical_raw_tokens(usage, :unavailable) do
    existing = Map.get(usage, :historical_raw_tokens, %{})

    current =
      %{
        baseline_tokens: nonnegative(usage[:baseline_tokens]),
        cumulative_tokens: nonnegative(usage[:cumulative_tokens]),
        inflight_tokens: nonnegative(usage[:inflight_tokens])
      }
      |> Enum.reject(fn {_key, value} -> value == 0 end)
      |> Map.new()

    Map.merge(existing, current)
  end

  defp legacy_usage_present?(usage) do
    Enum.any?([:baseline_tokens, :cumulative_tokens, :inflight_tokens, :overshoot_tokens], &(nonnegative(usage[&1]) > 0))
  end

  defp legacy_lifetime_usage?(assignment) when is_map(assignment) do
    usage = Map.get(assignment, :usage, %{})

    is_map(usage) and map_size(usage) > 0 and
      not Map.has_key?(assignment, :usage_source) and
      usage[:accounting_status] not in [:known, :unavailable]
  end

  defp normalize_delta(delta) do
    %{
      input_tokens: nonnegative(delta[:input_tokens]),
      output_tokens: nonnegative(delta[:output_tokens]),
      total_tokens: nonnegative(delta[:total_tokens]),
      cached_input_tokens: optional_nonnegative(delta[:cached_input_tokens])
    }
  end

  defp zero_delta, do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, cached_input_tokens: nil}

  defp optional_delta(_previous, raw) when not is_integer(raw) or raw < 0, do: nil
  defp optional_delta(previous, raw), do: max(raw - nonnegative(previous), 0)

  defp add_optional(existing, delta) when is_integer(delta) and delta >= 0, do: nonnegative(existing) + delta
  defp add_optional(existing, _delta), do: optional_nonnegative(existing)

  defp max_optional(existing, value) when is_integer(value) and value >= 0, do: max(nonnegative(existing), value)
  defp max_optional(existing, _value), do: optional_nonnegative(existing)

  defp optional_nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp optional_nonnegative(_value), do: nil

  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value), do: 0
end
