defmodule SymphonyElixir.Managed.Ownership do
  @moduledoc """
  Pure ownership and authenticated-principal rules for managed assignments.

  Authentication is performed by the managed HTTP boundary. This module only
  validates the server-supplied principal context and applies ownership
  compare-and-set rules to assignment maps.
  """

  @roles [:pm, :operator]
  @ownership_statuses [:owned, :unassigned, :needs_claim, :handoff_pending]

  @type principal :: %{
          principal_id: String.t(),
          role: :pm | :operator,
          project_scope: :all | [String.t()] | MapSet.t(),
          capability_id: String.t() | nil
        }
  @type ownership :: %{
          status: :owned | :unassigned | :needs_claim | :handoff_pending,
          pm_id: String.t() | nil,
          capability_id: String.t() | nil,
          ownership_revision: non_neg_integer(),
          changed_at: DateTime.t() | nil,
          last_handoff_id: String.t() | nil
        }

  @spec principal(map()) :: {:ok, principal()} | {:error, atom(), map()}
  def principal(context) when is_map(context) do
    value = Map.get(context, :principal, Map.get(context, "principal", context))
    principal_from_value(value)
  end

  def principal(_context), do: {:error, :principal_required, %{}}

  @spec unassigned() :: ownership()
  def unassigned do
    %{status: :unassigned, pm_id: nil, capability_id: nil, ownership_revision: 0, changed_at: nil, last_handoff_id: nil}
  end

  @spec needs_claim() :: ownership()
  def needs_claim, do: %{unassigned() | status: :needs_claim}

  @spec assigned(principal(), non_neg_integer()) :: ownership()
  def assigned(principal, revision \\ 1) when is_map(principal) and is_integer(revision) and revision >= 0 do
    %{
      unassigned()
      | status: :owned,
        pm_id: principal.principal_id,
        capability_id: principal.capability_id,
        ownership_revision: revision,
        changed_at: DateTime.utc_now()
    }
  end

  @spec project_allowed?(principal(), String.t() | nil) :: boolean()
  def project_allowed?(%{project_scope: :all}, project_id) when is_binary(project_id) and project_id != "", do: true
  def project_allowed?(%{project_scope: scope}, project_id) when is_list(scope) and is_binary(project_id), do: project_id in scope
  def project_allowed?(%{project_scope: %MapSet{} = scope}, project_id) when is_binary(project_id), do: MapSet.member?(scope, project_id)
  def project_allowed?(_principal, _project_id), do: false

  @spec operator?(principal()) :: boolean()
  def operator?(%{role: :operator}), do: true
  def operator?(_principal), do: false

  @spec owner?(map(), principal()) :: boolean()
  def owner?(assignment, %{principal_id: principal_id}) when is_map(assignment) and is_binary(principal_id) do
    ownership = ownership(assignment)
    ownership.status == :owned and ownership.pm_id == principal_id
  end

  def owner?(_assignment, _principal), do: false

  @spec authorize_project(principal(), String.t() | nil) :: :ok | {:error, atom(), map()}
  def authorize_project(_principal, nil), do: {:error, :project_required, %{}}
  def authorize_project(_principal, ""), do: {:error, :project_required, %{}}
  def authorize_project(%{role: :operator}, _project_id), do: :ok

  def authorize_project(%{role: :pm} = principal, project_id) do
    if project_allowed?(principal, project_id) do
      :ok
    else
      {:error, :project_out_of_scope, %{project_id: project_id}}
    end
  end

  def authorize_project(_principal, project_id), do: {:error, :principal_invalid, %{project_id: project_id}}

  @spec authorize_assignment(principal(), map(), String.t() | nil) :: :ok | {:error, atom(), map()}
  def authorize_assignment(principal, assignment, project_id) when is_map(assignment) do
    with :ok <- authorize_project(principal, project_id),
         :ok <- assignment_project_matches(assignment, project_id) do
      cond do
        operator?(principal) ->
          :ok

        owner?(assignment, principal) ->
          :ok

        ownership(assignment).status in [:needs_claim, :unassigned] ->
          {:error, :assignment_unowned, %{assignment_id: Map.get(assignment, :assignment_id)}}

        true ->
          {:error, :ownership_conflict, %{assignment_id: Map.get(assignment, :assignment_id), responsible_pm_id: ownership(assignment).pm_id}}
      end
    end
  end

  def authorize_assignment(_principal, _assignment, project_id), do: {:error, :assignment_invalid, %{project_id: project_id}}

  @spec expected_ownership_revision(map(), map()) :: :ok | {:error, atom(), map()}
  def expected_ownership_revision(assignment, args) when is_map(assignment) and is_map(args) do
    expected = value(args, :expected_ownership_revision)
    actual = ownership(assignment).ownership_revision

    cond do
      not is_integer(expected) -> {:error, :expected_ownership_revision_required, %{}}
      expected != actual -> {:error, :stale_ownership_revision, %{expected: expected, actual: actual}}
      true -> :ok
    end
  end

  def expected_ownership_revision(_assignment, _args), do: {:error, :expected_ownership_revision_required, %{}}

  @spec claim(map(), principal()) :: {:ok, map()} | {:error, atom(), map()}
  def claim(assignment, principal) when is_map(assignment) and is_map(principal) do
    current = ownership(assignment)

    case current.status do
      :unassigned ->
        {:ok, Map.put(assignment, :ownership, assigned(principal, current.ownership_revision + 1))}

      :needs_claim ->
        {:error, :operator_takeover_required, %{assignment_id: Map.get(assignment, :assignment_id)}}

      :owned ->
        {:error, :ownership_conflict, %{assignment_id: Map.get(assignment, :assignment_id), responsible_pm_id: current.pm_id}}

      :handoff_pending ->
        {:error, :handoff_pending, %{assignment_id: Map.get(assignment, :assignment_id)}}
    end
  end

  @spec transfer(map(), principal(), String.t() | nil) :: {:ok, map()} | {:error, atom(), map()}
  def transfer(assignment, target, handoff_id \\ nil) when is_map(assignment) and is_map(target) do
    current = ownership(assignment)

    if current.status == :owned and target.role == :pm and is_binary(target.principal_id) do
      {:ok,
       Map.put(
         assignment,
         :ownership,
         %{
           current
           | pm_id: target.principal_id,
             capability_id: target.capability_id,
             ownership_revision: current.ownership_revision + 1,
             changed_at: DateTime.utc_now(),
             last_handoff_id: handoff_id
         }
       )}
    else
      {:error, :assignment_not_owned, %{assignment_id: Map.get(assignment, :assignment_id)}}
    end
  end

  @spec takeover(map(), principal(), String.t() | nil) :: {:ok, map()} | {:error, atom(), map()}
  def takeover(assignment, target, handoff_id \\ nil) when is_map(assignment) and is_map(target) do
    current = ownership(assignment)

    if current.status in [:needs_claim, :unassigned, :owned] and target.role == :pm and is_binary(target.principal_id) do
      {:ok,
       Map.put(
         assignment,
         :ownership,
         %{
           current
           | status: :owned,
             pm_id: target.principal_id,
             capability_id: target.capability_id,
             ownership_revision: current.ownership_revision + 1,
             changed_at: DateTime.utc_now(),
             last_handoff_id: handoff_id
         }
       )}
    else
      {:error, :assignment_not_takeoverable, %{assignment_id: Map.get(assignment, :assignment_id)}}
    end
  end

  @spec ownership(map()) :: ownership()
  def ownership(assignment) when is_map(assignment) do
    value = Map.get(assignment, :ownership, Map.get(assignment, "ownership", %{}))
    status = value(value, :status)
    revision = value(value, :ownership_revision)

    %{
      status: if(status in @ownership_statuses, do: status, else: :unassigned),
      pm_id: text(value, :pm_id),
      capability_id: text(value, :capability_id),
      ownership_revision: if(is_integer(revision) and revision >= 0, do: revision, else: 0),
      changed_at: value(value, :changed_at),
      last_handoff_id: text(value, :last_handoff_id)
    }
  end

  def ownership(_assignment), do: unassigned()

  defp principal_from_value(value) when is_map(value) do
    principal_id = text(value, :principal_id)
    role = value(value, :role) |> normalize_role()
    scope = normalize_scope(value(value, :project_scope, :all))
    capability_id = text(value, :capability_id)

    cond do
      is_nil(principal_id) -> {:error, :principal_required, %{}}
      role not in @roles -> {:error, :principal_invalid, %{}}
      is_nil(scope) -> {:error, :principal_scope_invalid, %{}}
      true -> {:ok, %{principal_id: principal_id, role: role, project_scope: scope, capability_id: capability_id}}
    end
  end

  defp principal_from_value(_value), do: {:error, :principal_required, %{}}

  defp assignment_project_matches(assignment, project_id) do
    actual = text(assignment, :project_id)

    if actual == project_id do
      :ok
    else
      {:error, :assignment_project_mismatch, %{project_id: project_id, assignment_project_id: actual}}
    end
  end

  defp normalize_role(value) when value in @roles, do: value

  defp normalize_role(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "pm" -> :pm
      "operator" -> :operator
      _ -> :unknown
    end
  end

  defp normalize_role(_value), do: :unknown

  defp normalize_scope(:all), do: :all
  defp normalize_scope("all"), do: :all

  defp normalize_scope(scope) when is_list(scope) do
    if Enum.all?(scope, &(is_binary(&1) and String.trim(&1) != "")) do
      scope |> Enum.map(&String.trim/1) |> Enum.uniq()
    else
      nil
    end
  end

  defp normalize_scope(%MapSet{} = scope), do: scope

  defp normalize_scope(_scope), do: nil

  defp text(map, key) when is_map(map) do
    case value(map, key) do
      value when is_binary(value) -> String.trim(value) |> blank_to_nil()
      _ -> nil
    end
  end

  defp text(_map, _key), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp value(map, key, default \\ nil)
  defp value(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp value(_map, _key, default), do: default
end
