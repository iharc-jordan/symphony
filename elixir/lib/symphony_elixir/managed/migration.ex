defmodule SymphonyElixir.Managed.Migration do
  @moduledoc """
  Pure conversion of embedded managed journal state from version one to two.

  Migration keeps old request/canonical bytes intact and never replays a
  legacy control or provider effect. Pending legacy intents are visibly held
  for explicit operator reconciliation.
  """

  alias SymphonyElixir.Managed.Ownership
  alias SymphonyElixir.Managed.Resources

  @version 2
  @legacy_operator %{
    principal_id: "operator",
    role: :operator,
    project_scope: :all,
    capability_id: nil
  }
  @replayable_statuses [:pending, :effect_reconciled, "pending", "effect_reconciled"]

  @spec current_version() :: pos_integer()
  def current_version, do: @version

  @spec migrate(map()) :: {:ok, map()} | {:error, atom(), map()}
  def migrate(state), do: migrate(state, [])

  @spec migrate(map(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def migrate(state, opts) when is_map(state) do
    if migrated?(state), do: {:ok, state}, else: migrate_v1(state, opts)
  end

  def migrate(_state, _opts), do: {:error, :managed_state_invalid, %{}}

  @spec migrated?(map()) :: boolean()
  def migrated?(state) when is_map(state), do: get(state, :version) == @version
  def migrated?(_state), do: false

  defp migrate_v1(state, opts) do
    binding = get(state, :binding)
    assignments = get(state, :assignments, %{})

    with {:ok, projects, project_id} <- migrate_binding(binding),
         {:ok, migrated_assignments, conflicts} <- migrate_assignments(assignments, project_id, opts) do
      {review_intents, review_reconciliation} =
        migrate_intents(get(state, :review_intents, %{}), projects, migrated_assignments)

      {effect_intents, effect_reconciliation} =
        migrate_intents(get(state, :effect_intents, %{}), projects, migrated_assignments)

      reconciliation_ids = Enum.uniq(review_reconciliation ++ effect_reconciliation)

      reconciliation_assignment_ids =
        (reconciliation_assignment_ids(review_intents) ++ reconciliation_assignment_ids(effect_intents))
        |> Enum.uniq()

      migrated =
        state
        |> Map.put(:version, @version)
        |> Map.put(:projects, projects)
        |> Map.put(:assignments, mark_assignment_reconciliation(migrated_assignments, reconciliation_assignment_ids))
        |> Map.put(:review_intents, review_intents)
        |> Map.put(:effect_intents, effect_intents)
        |> Map.put(:migration, %{
          from: 1,
          to: @version,
          status: if(map_size(migrated_assignments) == 0 and conflicts == [], do: :complete, else: :needs_claim),
          conflicts: conflicts,
          reconciliation_required: reconciliation_ids
        })
        |> Map.put(:principals, migrate_principals(get(state, :principals, %{})))
        |> migrate_request_records()
        |> Map.delete(:binding)
        |> Map.delete("binding")

      {:ok, migrated}
    end
  end

  defp migrate_binding(nil), do: {:ok, %{}, nil}

  defp migrate_binding(binding) when is_map(binding) do
    project_id = text(binding, :project_id)

    if is_nil(project_id) do
      {:error, :project_binding_invalid, %{}}
    else
      project =
        binding
        |> normalize_known_keys()
        |> Map.put(:project_id, project_id)
        |> Map.put(:revision, nonnegative_integer(get(binding, :revision), 0))
        |> Map.put(:dispatch_paused, get(binding, :dispatch_paused, false) == true)

      {:ok, %{project_id => project}, project_id}
    end
  end

  defp migrate_binding(_binding), do: {:error, :project_binding_invalid, %{}}

  defp migrate_assignments(assignments, project_id, opts) when is_map(assignments) do
    allow_legacy = Keyword.get(opts, :allow_legacy_resources, true)

    Enum.reduce_while(assignments, {:ok, %{}, []}, fn {id, assignment}, {:ok, acc, conflicts} ->
      case migrate_assignment(id, assignment, project_id, allow_legacy) do
        {:ok, migrated, identity} ->
          conflict_ids =
            if identity && Enum.any?(acc, fn {_existing_id, existing} -> canonical_identity(existing) == identity end),
              do: [to_string(id)],
              else: []

          {:cont, {:ok, Map.put(acc, id, migrated), conflicts ++ conflict_ids}}

        {:error, code, details} ->
          {:halt, {:error, code, Map.put(details, :assignment_id, id)}}
      end
    end)
  end

  defp migrate_assignments(_assignments, _project_id, _opts), do: {:error, :assignments_invalid, %{}}

  defp migrate_assignment(id, assignment, project_id, allow_legacy) when is_map(assignment) do
    assignment_project_id = text(assignment, :project_id) || project_id
    resources = get(assignment, :resources, [])

    with {:ok, normalized_resources} <- Resources.normalize_all(resources, allow_legacy: allow_legacy) do
      identity = canonical_identity(assignment)

      migrated =
        assignment
        |> normalize_known_keys()
        |> Map.put(:assignment_id, text(assignment, :assignment_id) || to_string(id))
        |> maybe_put(:project_id, assignment_project_id)
        |> Map.put(:resources, normalized_resources)
        |> Map.put(:ownership, Ownership.needs_claim())
        |> maybe_put(:underlying_identity, identity_map(assignment, identity))

      {:ok, migrated, identity}
    end
  end

  defp migrate_assignment(_id, _assignment, _project_id, _allow_legacy), do: {:error, :assignment_invalid, %{}}

  defp canonical_identity(assignment) when is_map(assignment) do
    provider = text(assignment, :provider) || "github"
    repository = text(assignment, :repository)
    native_repository_id = text(assignment, :native_repository_id) || text(assignment, :repository_id) || text(assignment, :repository_node_id)
    native_issue_id = text(assignment, :native_issue_id) || text(assignment, :issue_id) || text(assignment, :issue_node_id)
    issue_number = get(assignment, :issue_number)

    cond do
      is_binary(native_issue_id) -> {provider, native_repository_id || repository || "", native_issue_id}
      is_binary(repository) and is_integer(issue_number) -> {provider, String.downcase(repository), issue_number}
      true -> nil
    end
  end

  defp canonical_identity(_assignment), do: nil

  defp identity_map(_assignment, nil), do: nil

  defp identity_map(assignment, {provider, repository, issue}) do
    native_issue_id = text(assignment, :native_issue_id) || text(assignment, :issue_id) || text(assignment, :issue_node_id)
    native_repository_id = text(assignment, :native_repository_id) || text(assignment, :repository_id) || text(assignment, :repository_node_id)

    if native_issue_id do
      %{provider: provider, repository: text(assignment, :repository) || repository, native_repository_id: native_repository_id, native_issue_id: native_issue_id}
    else
      %{provider: provider, repository: repository, issue_number: issue}
    end
  end

  defp migrate_intents(intents, projects, assignments) when is_map(intents) do
    Enum.reduce(intents, {%{}, []}, fn {request_id, raw_intent}, {acc, reconciliation_ids} ->
      # Keep the persisted request map byte-shape intact. Helpers below read
      # atom and string keys without normalizing the request or canonical.
      intent = if is_map(raw_intent), do: raw_intent, else: %{intent: raw_intent}
      assignment_id = text(intent, :assignment_id) || request_assignment_id(intent)
      assignment = Map.get(assignments, assignment_id) || Map.get(assignments, to_string(assignment_id || ""))
      project_id = text(intent, :project_id) || (assignment && text(assignment, :project_id))
      binding = project_id && Map.get(projects, project_id)
      ownership_revision = assignment && Ownership.ownership(assignment).ownership_revision

      migrated =
        intent
        |> Map.put(:legacy_intent, true)
        |> Map.put(:provenance, :legacy_intent)
        |> Map.put(:principal_context, @legacy_operator)
        |> maybe_put(:assignment_id, assignment_id)
        |> maybe_put(:project_id, project_id)
        |> maybe_put(:ownership_revision, ownership_revision)
        |> maybe_put(:binding, binding)

      needs_reconciliation? = raw_intent_pending?(intent)
      migrated = if needs_reconciliation?, do: Map.put(migrated, :status, :needs_operator_reconciliation), else: migrated
      next_ids = if needs_reconciliation?, do: [to_string(request_id) | reconciliation_ids], else: reconciliation_ids
      {Map.put(acc, request_id, migrated), next_ids}
    end)
  end

  defp migrate_intents(_intents, _projects, _assignments), do: {%{}, []}

  defp raw_intent_pending?(intent), do: get(intent, :status) in @replayable_statuses

  defp request_assignment_id(intent) do
    case get(intent, :request) do
      request when is_map(request) -> text(get(request, :args, %{}), :assignment_id)
      _ -> nil
    end
  end

  defp mark_assignment_reconciliation(assignments, assignment_ids) when is_map(assignments) do
    Enum.reduce(assignments, %{}, fn {id, assignment}, acc ->
      pending? = is_map(assignment) and text(assignment, :assignment_id) in assignment_ids
      value = if pending?, do: Map.put(assignment, :operator_reconciliation_required, true), else: assignment
      Map.put(acc, id, value)
    end)
  end

  defp reconciliation_assignment_ids(intents) when is_map(intents) do
    intents
    |> Map.values()
    |> Enum.filter(&(is_map(&1) and get(&1, :status) == :needs_operator_reconciliation))
    |> Enum.map(&text(&1, :assignment_id))
    |> Enum.filter(&is_binary/1)
  end

  defp reconciliation_assignment_ids(_intents), do: []

  defp migrate_principals(principals) when is_map(principals) do
    Map.put_new(principals, "operator", %{principal_id: "operator", role: :operator, project_scope: :all, legacy: true})
  end

  defp migrate_principals(_principals), do: %{"operator" => %{principal_id: "operator", role: :operator, project_scope: :all, legacy: true}}

  # Historical request records are committed records, so their canonical and
  # response stay untouched. They are explicitly attributed to the operator
  # authority that owned the single v1 service credential.
  defp migrate_request_records(state) do
    requests = get(state, :requests, %{})

    if is_map(requests) do
      migrated =
        Map.new(requests, fn {request_id, record} ->
          value =
            if is_map(record) do
              record
              |> Map.put_new(:principal_id, "operator")
              |> Map.put_new(:capability_id, nil)
              |> Map.put(:legacy_request, true)
            else
              record
            end

          {request_id, value}
        end)

      Map.put(state, :requests, migrated)
    else
      state
    end
  end

  defp normalize_known_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {known_key(key), normalize_known_value(value)} end)
  end

  defp normalize_known_value(value) when is_map(value), do: normalize_known_keys(value)
  defp normalize_known_value(value) when is_list(value), do: Enum.map(value, &normalize_known_value/1)
  defp normalize_known_value(value), do: value

  defp known_key(key) when is_atom(key), do: key

  defp known_key(key)
       when key in [
              "project_id",
              "assignment_id",
              "request_id",
              "principal_id",
              "capability_id",
              "role",
              "project_scope",
              "resources",
              "ownership",
              "status",
              "request",
              "args",
              "revision",
              "expected_revision",
              "expected_ownership_revision",
              "project_item_id",
              "native_project_item_id",
              "native_issue_id",
              "native_repository_id",
              "repository_id",
              "repository_node_id",
              "issue_id",
              "issue_node_id",
              "provider",
              "repository",
              "issue_number",
              "binding",
              "target",
              "auto",
              "context",
              "canonical",
              "response",
              "operation",
              "reason",
              "project",
              "status_field_id",
              "status_options",
              "repositories",
              "project_number",
              "dispatch_paused",
              "phase",
              "board_state",
              "owner",
              "underlying_issue_id",
              "underlying_identity",
              "dependencies",
              "route",
              "base_commit",
              "at",
              "stop_pending",
              "attempt_id",
              "thread_id",
              "session_id",
              "workspace",
              "usage",
              "reports",
              "retry_count",
              "turns_reserved",
              "pending_effect",
              "event_cursor",
              "control_revision",
              "principal_context",
              "legacy_intent",
              "provenance",
              "operator_reconciliation_required"
            ],
       do: String.to_atom(key)

  defp known_key(key), do: key

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default

  defp text(map, key) when is_map(map) do
    case get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end

  defp text(_map, _key), do: nil

  defp nonnegative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value, default), do: default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
