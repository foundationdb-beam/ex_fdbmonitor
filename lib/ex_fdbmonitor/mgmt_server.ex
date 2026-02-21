require Logger

defmodule ExFdbmonitor.MgmtServer do
  @moduledoc """
  A DGenServer that serializes actions across all nodes.

  Nodes submit fdbcli commands via `exec/1`. The DGenServer processes
  them one at a time, ensuring commands from different nodes don't
  interleave on a cluster that is still being configured.
  """

  use DGenServer

  defstruct nodes: %{}

  # {name, version}
  @tuid {"ExFdbmonitor.MgmtServer", 0}

  def start_link({db, dir}) do
    DGenServer.start_link(__MODULE__, [], name: __MODULE__, tenant: {db, dir})
  end

  @doc """
  Execute `fdbcli_args` through the serialized server.
  """
  def exec(fdbcli_args) do
    DGenServer.call(__MODULE__, {:exec, fdbcli_args}, :infinity)
  end

  @doc """
  Register a mapping from `machine_id` to `node_name` in the server state.
  """
  def register_node(machine_id, node_name) do
    DGenServer.call(__MODULE__, {:register_node, machine_id, node_name}, :infinity)
  end

  @doc """
  Look up the machine_id for a given node name.
  """
  def get_machine_id(node_name) do
    DGenServer.call(__MODULE__, {:get_machine_id, node_name}, :infinity)
  end

  @doc """
  Exclude all FDB processes belonging to `node_name` from the cluster.

  Raises if the node has no registered machine_id.
  """
  def exclude(node_name) do
    DGenServer.call(__MODULE__, {:exclude, node_name}, :infinity)
  end

  @doc """
  Include all FDB processes belonging to `node_name` back into the cluster.

  Returns `{:error, {:unknown_node, node_name}}` if the node has no registered machine_id.
  """
  def include(node_name) do
    DGenServer.call(__MODULE__, {:include, node_name}, :infinity)
  end

  # --- DGenServer callbacks ---

  @impl true
  def init([]), do: {:ok, @tuid, %__MODULE__{}}

  @impl true
  def handle_call({:register_node, machine_id, node_name}, _from, state) do
    {:reply, :ok, %{state | nodes: Map.put(state.nodes, node_name, machine_id)}}
  end

  def handle_call({:get_machine_id, node_name}, _from, state) do
    {:reply, Map.fetch(state.nodes, node_name), state}
  end

  def handle_call({:include, node_name}, _from, state) do
    case Map.fetch(state.nodes, node_name) do
      {:ok, _machine_id} ->
        {:lock, state}

      :error ->
        {:reply, {:error, {:unknown_node, node_name}}, state}
    end
  end

  def handle_call({:exec, _fdbcli_args}, _from, state) do
    {:lock, state}
  end

  def handle_call({:exclude, node_name}, _from, state) do
    case Map.fetch(state.nodes, node_name) do
      {:ok, _machine_id} ->
        {:lock, state}

      :error ->
        {:reply, {:error, {:unknown_node, node_name}}, state}
    end
  end

  @impl true
  def handle_locked({:call, _from}, {:exec, fdbcli_args}, state) do
    Logger.notice("#{node()} fdbcli server exec #{inspect(fdbcli_args)}")
    result = ExFdbmonitor.Fdbcli.exec(fdbcli_args)
    {:reply, result, state}
  end

  def handle_locked({:call, _from}, {:exclude, node_name}, state) do
    machine_id = state.nodes[node_name]
    fdbcli_args = ["exclude", "locality_machineid:#{machine_id}"]
    Logger.notice("#{node()} fdbcli server exec #{inspect(fdbcli_args)}")
    result = ExFdbmonitor.Fdbcli.exec(fdbcli_args)
    {:reply, result, state}
  end

  def handle_locked({:call, _from}, {:include, node_name}, state) do
    machine_id = state.nodes[node_name]
    fdbcli_args = ["include", "locality_machineid:#{machine_id}"]
    Logger.notice("#{node()} fdbcli server exec #{inspect(fdbcli_args)}")
    result = ExFdbmonitor.Fdbcli.exec(fdbcli_args)
    {:reply, result, state}
  end
end
