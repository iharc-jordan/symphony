defmodule SymphonyElixir.ManagedControlTestServer do
  use GenServer

  def start(mode, opts \\ []) do
    GenServer.start(__MODULE__, mode, opts)
  end

  @impl true
  def init(mode), do: {:ok, mode}

  @impl true
  def handle_call(:managed_state, _from, :ok), do: {:reply, {:ok, %{status: :ok}}, :ok}

  def handle_call(:managed_state, _from, :timeout) do
    Process.sleep(100)
    {:reply, {:ok, %{status: :ok}}, :timeout}
  end

  def handle_call(:managed_state, _from, :crash), do: exit(:managed_control_test_crash)

  def handle_call({:managed_events, after_cursor, limit}, _from, state) do
    {:reply, {:ok, [%{after_cursor: after_cursor, limit: limit}]}, state}
  end

  def handle_call({:managed_control, _envelope, _principal}, _from, :triple_error) do
    {:reply, {:error, :invalid_argument, %{field: :envelope}}, :triple_error}
  end

  def handle_call({:managed_control, _envelope, _principal}, _from, state) do
    {:reply, {:ok, %{accepted: true}}, state}
  end

  def handle_call({:managed_reconcile, assignment_id, facts}, _from, state) do
    {:reply, {:ok, %{assignment_id: assignment_id, facts: facts}}, state}
  end
end

defmodule SymphonyElixir.ManagedControlTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Managed.{Control, Rules}

  test "operations exposes the rules allowlist" do
    assert Control.operations() == Rules.allowed_operations()
  end

  test "calls named orchestrators and caps event limits" do
    name = Module.concat(__MODULE__, :named_server)
    {:ok, pid} = SymphonyElixir.ManagedControlTestServer.start(:ok, name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:ok, %{status: :ok}} = Control.state(name)
    assert {:ok, [%{after_cursor: 7, limit: 100}]} = Control.events(name, 7, 500)
    assert {:ok, %{accepted: true}} = Control.submit(name, %{request_id: "r1"})

    assert {:ok, %{assignment_id: "a1", facts: %{provider_state: :ready}}} =
             Control.reconcile(name, "a1", %{provider_state: :ready})
  end

  test "passes through structured control errors" do
    {:ok, pid} = SymphonyElixir.ManagedControlTestServer.start(:triple_error)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:error, :invalid_argument, %{field: :envelope}} = Control.submit(pid, %{})
  end

  test "returns unavailable for invalid and missing orchestrators" do
    assert {:error, :orchestrator_unavailable} = Control.state(%{})
    assert {:error, :orchestrator_unavailable} = Control.state(:managed_control_missing)
  end

  test "normalizes GenServer call timeouts" do
    {:ok, pid} = SymphonyElixir.ManagedControlTestServer.start(:timeout)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :kill) end)

    assert {:error, :timeout} = Control.state(pid, 5)
  end

  test "normalizes exits from an available orchestrator" do
    {:ok, pid} = SymphonyElixir.ManagedControlTestServer.start(:crash)

    assert {:error, {:managed_control_test_crash, {GenServer, :call, [^pid, :managed_state, 1000]}}} =
             Control.state(pid, 1000)
  end
end
