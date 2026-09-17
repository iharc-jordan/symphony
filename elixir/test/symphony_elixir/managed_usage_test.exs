defmodule SymphonyElixir.ManagedUsageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Managed.Usage

  test "same source thread resumes from its durable raw watermark exactly once" do
    assignment = %{
      thread_id: "thread-1",
      usage: %{input_tokens: 19_000_000, output_tokens: 980_559, total_tokens: 19_980_559, seconds_running: 12}
    }

    assignment = Usage.start_source(assignment, "thread-1", "attempt-2")
    source = Usage.source_for(assignment, "thread-1")
    assert source.total_tokens == 19_980_559

    raw = %{input_tokens: 21_000_000, output_tokens: 1_053_595, total_tokens: 22_053_595}
    delta = Usage.raw_delta(Usage.source_raw(source), raw)
    assert delta.total_tokens == 2_073_036

    updated = Usage.record_delta(assignment, "thread-1", "attempt-2", raw, delta)
    assert updated.usage.total_tokens == 22_053_595
    assert updated.usage_source.total_tokens == 22_053_595

    duplicate = Usage.record_delta(updated, "thread-1", "attempt-2", raw, %{input_tokens: 0, output_tokens: 0, total_tokens: 0})
    assert duplicate.usage.total_tokens == 22_053_595

    out_of_order =
      Usage.record_delta(
        duplicate,
        "thread-1",
        "attempt-2",
        %{input_tokens: 20_000_000, output_tokens: 1_000_000, total_tokens: 21_000_000},
        %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      )

    assert out_of_order.usage.total_tokens == 22_053_595
    assert out_of_order.usage_source.total_tokens == 22_053_595
  end

  test "a new source thread starts from zero without resetting assignment lifetime usage" do
    assignment = %{
      thread_id: "thread-1",
      usage_source: %{thread_id: "thread-1", input_tokens: 30, output_tokens: 7, total_tokens: 37},
      usage: %{input_tokens: 30, output_tokens: 7, total_tokens: 37, seconds_running: 4, accounting_status: :known}
    }

    assignment = Usage.start_source(assignment, "thread-2", "attempt-3")
    assert Usage.source_for(assignment, "thread-2").total_tokens == 0

    updated =
      Usage.record_delta(
        assignment,
        "thread-2",
        "attempt-3",
        %{input_tokens: 4, output_tokens: 2, total_tokens: 6},
        %{input_tokens: 4, output_tokens: 2, total_tokens: 6}
      )

    assert updated.usage.total_tokens == 43
    assert updated.usage_source.thread_id == "thread-2"
    assert updated.usage_source.total_tokens == 6
  end

  test "cached input is an optional source watermark and is not replayed into total usage" do
    assignment =
      Usage.start_source(
        %{usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, accounting_status: :known}},
        "thread-cache",
        "attempt-cache"
      )

    raw = %{input_tokens: 100, output_tokens: 20, total_tokens: 120, cached_input_tokens: 70}
    delta = Usage.raw_delta(Usage.source_raw(Usage.source_for(assignment, "thread-cache")), raw)

    assert delta.total_tokens == 120
    assert delta.cached_input_tokens == 70

    recorded = Usage.record_delta(assignment, "thread-cache", "attempt-cache", raw, delta)
    assert recorded.usage.total_tokens == 120
    assert recorded.usage.cached_input_tokens == 70
    assert recorded.usage_source.cached_input_tokens == 70

    replay = Usage.raw_delta(Usage.source_raw(recorded.usage_source), raw)
    assert replay.total_tokens == 0
    assert replay.cached_input_tokens == 0

    unchanged = Usage.record_delta(recorded, "thread-cache", "attempt-cache", raw, replay)
    assert unchanged.usage.total_tokens == 120
    assert unchanged.usage.cached_input_tokens == 70
  end

  test "legacy aggregate remains unavailable and preserves historical raw values across normalization" do
    aggregate =
      Usage.normalize_aggregate(%{
        baseline_tokens: 19_980_559,
        cumulative_tokens: 22_053_595,
        inflight_tokens: 7
      })

    assert aggregate.accounting_status == :unavailable
    assert aggregate.cumulative_tokens == 0
    assert aggregate.historical_raw_tokens.cumulative_tokens == 22_053_595

    normalized = Usage.normalize_aggregate(aggregate)
    assert normalized.accounting_status == :unavailable
    assert normalized.historical_raw_tokens.cumulative_tokens == 22_053_595
    assert normalized.historical_raw_tokens.baseline_tokens == 19_980_559
  end

  test "starting a source cannot promote unqualified legacy lifetime counters" do
    assignment =
      Usage.start_source(
        %{thread_id: "legacy-thread", usage: %{input_tokens: 12, output_tokens: 3, total_tokens: 15}},
        "legacy-thread",
        "attempt-legacy"
      )

    recorded =
      Usage.record_delta(
        assignment,
        "legacy-thread",
        "attempt-legacy",
        %{input_tokens: 14, output_tokens: 4, total_tokens: 18},
        %{input_tokens: 2, output_tokens: 1, total_tokens: 3}
      )

    assert recorded.usage.total_tokens == 18
    assert recorded.usage.accounting_status == :unavailable
    assert recorded.usage.runtime_complete == false
  end

  test "inactive legacy lifetime usage becomes explicitly unavailable during recovery" do
    recovered =
      Usage.clear_assignment_inflight(%{
        phase: :accepted,
        usage: %{input_tokens: 12, output_tokens: 3, total_tokens: 15, seconds_running: 9}
      })

    assert recovered.usage.total_tokens == 15
    assert recovered.usage.seconds_running == 9
    assert recovered.usage.accounting_status == :unavailable
    assert recovered.usage.runtime_complete == false
  end

  test "usage fallbacks return neutral values for invalid input" do
    neutral = Usage.new_aggregate()
    zero = %{input_tokens: 0, output_tokens: 0, total_tokens: 0, cached_input_tokens: nil}

    assert Usage.normalize_aggregate(:invalid) == neutral
    assert Usage.accounting_status(:invalid) == :known
    assert Usage.add_aggregate_delta(:invalid, -1, nil) == neutral
    assert Usage.complete_aggregate_attempt(:invalid, -1, nil) == neutral
    assert Usage.clear_inflight(:invalid) == neutral
    assert Usage.source_for(:invalid, "fallback").thread_id == "fallback"
    assert Usage.source_for(:invalid, :invalid).thread_id == nil
    assert Usage.start_source(:invalid, :invalid, :invalid) == :invalid
    assert Usage.source_raw(:invalid) == zero
    assert Usage.record_delta(:invalid, "thread", "attempt", %{}, %{}) == :invalid
    assert Usage.complete_attempt(:invalid, nil, "attempt", %{}, 0) == {:invalid, zero, 0}
    assert Usage.normalize_assignment(:invalid) == :invalid
    assert Usage.clear_assignment_inflight(:invalid) == :invalid
    assert Usage.raw_delta(:invalid, :invalid) == zero
  end

  test "aggregate caps and source state retain their accounting status" do
    unavailable = Usage.normalize_aggregate(%{cumulative_tokens: 8})
    assert Usage.add_aggregate_delta(unavailable, 2, 1).accounting_status == :unavailable
    assert Usage.complete_aggregate_attempt(unavailable, 0, 1).accounting_status == :unavailable

    completed =
      Usage.new_aggregate()
      |> Usage.add_aggregate_delta(3, nil)
      |> Usage.complete_aggregate_attempt(1, 2)

    assert completed.inflight_tokens == 2
    assert completed.overshoot_tokens == 1
    assert completed.cap_reached

    expected = Usage.start_source(%{}, "thread", "expected-attempt")

    mismatched =
      Usage.record_delta(
        expected,
        "thread",
        "different-attempt",
        %{input_tokens: 4, output_tokens: 2, total_tokens: 6},
        %{input_tokens: 4, output_tokens: 2, total_tokens: 6}
      )

    assert mismatched.usage.total_tokens == 0
    assert mismatched.usage_source.total_tokens == 6

    legacy =
      Usage.record_delta(
        %{thread_id: "legacy-thread", usage: %{input_tokens: 4, output_tokens: 2, total_tokens: 6}},
        "legacy-thread",
        "attempt",
        %{input_tokens: 4, output_tokens: 2, total_tokens: 6},
        %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      )

    assert legacy.usage.accounting_status == :unavailable

    cleared = Usage.clear_assignment_inflight(mismatched)
    assert cleared.usage_source.active_attempt_id == nil
    assert cleared.usage_source.inflight_tokens == 0
  end

  test "usage normalization handles unbounded and incomplete source records" do
    running = Usage.add_aggregate_delta(Usage.new_aggregate(), 3, nil)
    assert Usage.clear_inflight(running).inflight_tokens == 0
    assert Usage.complete_aggregate_attempt(running, 1, nil).cap_reached == false

    normalized = Usage.normalize_aggregate(%{accounting_status: :known, historical_raw_tokens: :invalid})
    assert normalized.historical_raw_tokens == %{}
    assert Usage.source_for(%{thread_id: "legacy", usage: :invalid}, "legacy").total_tokens == 0

    {completed, delta, persisted_inflight} =
      Usage.complete_attempt(%{}, nil, "attempt-no-thread", %{input_tokens: 2, output_tokens: 1, total_tokens: 3}, 4)

    assert completed.usage.total_tokens == 3
    assert completed.usage_source.thread_id == nil
    assert delta.total_tokens == 3
    assert persisted_inflight == 0
  end

  test "completion adds only the raw watermark not already persisted and clears attempt inflight" do
    assignment =
      %{
        usage: %{
          input_tokens: 100,
          output_tokens: 20,
          total_tokens: 120,
          seconds_running: 9,
          accounting_status: :known
        },
        usage_source: %{
          thread_id: "thread-1",
          input_tokens: 100,
          output_tokens: 20,
          total_tokens: 120,
          active_attempt_id: "attempt-4",
          inflight_input_tokens: 5,
          inflight_output_tokens: 1,
          inflight_tokens: 6
        }
      }

    {completed, delta, inflight} =
      Usage.complete_attempt(
        assignment,
        "thread-1",
        "attempt-4",
        %{input_tokens: 105, output_tokens: 21, total_tokens: 126},
        15
      )

    assert delta.total_tokens == 6
    assert inflight == 6
    assert completed.usage.total_tokens == 126
    assert completed.usage.seconds_running == 24
    assert completed.usage_source.inflight_tokens == 0

    {replayed, replay_delta, replay_inflight} =
      Usage.complete_attempt(completed, "thread-1", "attempt-4", %{input_tokens: 105, output_tokens: 21, total_tokens: 126}, 15)

    assert replayed == completed
    assert replay_delta.total_tokens == 0
    assert replay_inflight == 0
  end
end
