defmodule SymphonyElixir.Managed.Projection do
  @moduledoc """
  A compact GitHub card projection of journal-owned PM responsibility. It never
  changes issue requirements or controls worker execution. Failed synchronization
  remains visible and retryable in the same journal.
  """

  @fields [:phase, :ownership, :thread_id, :worker_active, :stop_pending, :dispatch_paused, :blocked_reason]

  @spec mark_changes(map(), map(), DateTime.t()) :: map()
  def mark_changes(previous, current, now \\ DateTime.utc_now()) do
    assignments =
      Map.new(current.assignments, fn {id, assignment} ->
        binding = get_in(current, [:projects, assignment[:project_id]]) || %{}
        previous_assignment = get_in(previous, [:assignments, id]) || %{}

        previous_field = get_in(previous, [:projects, assignment[:project_id], :projection_field_id])

        changed =
          Map.take(previous_assignment, @fields) != Map.take(assignment, @fields) or
            previous_field != binding[:projection_field_id] or
            principal_label(previous, assignment) != principal_label(current, assignment)

        if is_binary(binding[:projection_field_id]) and changed do
          revision = (get_in(assignment, [:projection, :revision]) || 0) + 1
          projection = %{status: :pending, revision: revision, updated_at: now}
          {id, Map.put(assignment, :projection, projection)}
        else
          {id, assignment}
        end
      end)

    Map.put(current, :assignments, assignments)
  end

  @spec ready(map(), DateTime.t()) :: [{String.t(), map()}]
  def ready(data, now \\ DateTime.utc_now()) do
    Enum.filter(data.assignments, fn {_id, assignment} ->
      case assignment[:projection] do
        %{status: :pending} -> true
        %{status: :failed, retry_at: %DateTime{} = retry_at} -> DateTime.compare(now, retry_at) != :lt
        _ -> false
      end
    end)
  end

  @spec finish(map(), String.t(), non_neg_integer(), term(), DateTime.t()) :: map()
  def finish(data, assignment_id, revision, result, now \\ DateTime.utc_now()) do
    case get_in(data, [:assignments, assignment_id, :projection]) do
      %{revision: ^revision} = projection ->
        next =
          if result == :ok do
            projection |> Map.merge(%{status: :synced, synced_at: now}) |> Map.drop([:error, :retry_at])
          else
            Map.merge(projection, %{status: :failed, error: :github_projection_failed, retry_at: DateTime.add(now, 30, :second)})
          end

        put_in(data, [:assignments, assignment_id, :projection], next)

      _ ->
        data
    end
  end

  @spec text(map(), map()) :: String.t()
  def text(data, assignment) do
    owner = get_in(assignment, [:ownership, :pm_id]) || "unassigned"
    label = principal_label(data, assignment) |> to_string() |> String.replace(~r/[\r\n\t]/, " ") |> String.slice(0, 120)
    phase = assignment[:phase] || :unknown
    worker = if assignment[:worker_active] == true, do: "1 active", else: "0 active"
    attention = if phase == :review, do: "PM review required", else: to_string(phase)
    updated = get_in(assignment, [:projection, :updated_at]) |> to_string()
    "PM: #{label} (#{owner}) | Workers: #{worker} | Work: #{attention} | Updated: #{updated}"
  end

  defp principal_label(data, assignment) do
    owner = get_in(assignment, [:ownership, :pm_id])
    get_in(data, [:principals, owner, :display_name]) || owner || "Unassigned"
  end
end
