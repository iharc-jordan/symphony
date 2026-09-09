defmodule SymphonyElixir.Managed.Control do
  @moduledoc """
  Synchronous facade for managed controls owned by the Orchestrator.

  It contains no state or process. Calls are serialized by the supplied
  orchestrator GenServer.
  """

  alias SymphonyElixir.Managed.Rules

  @spec state(GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  def state(orchestrator \\ SymphonyElixir.Orchestrator, timeout \\ 15_000) do
    call(orchestrator, :managed_state, timeout)
  end

  @spec events(GenServer.server(), non_neg_integer(), non_neg_integer(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def events(orchestrator \\ SymphonyElixir.Orchestrator, after_cursor, limit \\ 100, timeout \\ 15_000) do
    call(orchestrator, {:managed_events, after_cursor, min(limit, 100)}, timeout)
  end

  @spec submit(GenServer.server(), map(), timeout()) ::
          {:ok, map()} | {:error, term()} | {:error, atom(), map()}
  def submit(orchestrator \\ SymphonyElixir.Orchestrator, envelope, timeout \\ 15_000)
      when is_map(envelope) do
    call(orchestrator, {:managed_control, envelope}, timeout)
  end

  @doc false
  @spec reconcile(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()} | {:error, atom(), map()}
  def reconcile(orchestrator \\ SymphonyElixir.Orchestrator, assignment_id, facts, timeout \\ 15_000)
      when is_binary(assignment_id) and is_map(facts) do
    call(orchestrator, {:managed_reconcile, assignment_id, facts}, timeout)
  end

  @spec operations() :: [atom()]
  def operations, do: Rules.allowed_operations()

  defp server_available?(server) when is_pid(server), do: Process.alive?(server)
  defp server_available?(server) when is_atom(server), do: is_pid(Process.whereis(server))
  defp server_available?(_server), do: false

  defp call(orchestrator, message, timeout) do
    if server_available?(orchestrator) do
      try do
        GenServer.call(orchestrator, message, timeout)
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, reason}
      end
    else
      {:error, :orchestrator_unavailable}
    end
  end
end
