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

  @min_nodes %{"single" => 1, "double" => 3, "triple" => 5}
  @valid_modes Map.keys(@min_nodes)
  @mode_order %{"single" => 1, "double" => 2, "triple" => 3}

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

  @doc """
  Scale the cluster down to `target_mode` by removing `nodes_to_remove`.

  Executes under the DGenServer lock:
  1. `configure <target_mode>`
  2. Set coordinators to surviving nodes
  3. `exclude` each departing node (blocks until data moved)

  The caller is responsible for stopping workers on the removed nodes after
  this call returns.
  """
  def scale_down(target_mode, nodes_to_remove) do
    DGenServer.call(__MODULE__, {:scale_down, target_mode, nodes_to_remove}, :infinity)
  end

  @doc """
  Scale the cluster up to `target_mode` by adding `nodes_to_add`.

  The caller must start workers on the new nodes *before* calling this.
  Executes under the DGenServer lock:
  1. `include` each new node
  2. `coordinators auto`
  3. `configure <target_mode>`
  """
  def scale_up(target_mode, nodes_to_add) do
    DGenServer.call(__MODULE__, {:scale_up, target_mode, nodes_to_add}, :infinity)
  end

  @doc """
  Declare the desired redundancy mode for the cluster.

  Each node calls this during bootstrap. When the number of registered
  nodes reaches the minimum for `target_mode`, coordinators and redundancy
  are configured. Calls before the threshold is met are no-ops.
  """
  def set_redundancy_mode(target_mode) do
    DGenServer.call(__MODULE__, {:set_redundancy_mode, target_mode}, :infinity)
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

  def handle_call({:scale_down, target_mode, nodes_to_remove}, _from, state) do
    with :ok <- validate_mode(target_mode),
         :ok <- validate_known_nodes(nodes_to_remove, state),
         surviving = Map.keys(state.nodes) -- nodes_to_remove,
         :ok <- validate_min_nodes(target_mode, surviving) do
      {:lock, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:scale_up, target_mode, nodes_to_add}, _from, state) do
    with :ok <- validate_mode(target_mode),
         :ok <- validate_known_nodes(nodes_to_add, state),
         all_nodes = Map.keys(state.nodes),
         :ok <- validate_min_nodes(target_mode, all_nodes) do
      {:lock, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:set_redundancy_mode, target_mode}, _from, state) do
    with :ok <- validate_mode(target_mode) do
      all_nodes = Map.keys(state.nodes)

      if length(all_nodes) >= @min_nodes[target_mode] do
        {:lock, state}
      else
        {:reply, :ok, state}
      end
    else
      {:error, _} = error -> {:reply, error, state}
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

  def handle_locked({:call, _from}, {:scale_down, target_mode, nodes_to_remove}, state) do
    surviving = Map.keys(state.nodes) -- nodes_to_remove

    with {:ok, _} <- fdbcli_exec(["configure", target_mode]),
         {:ok, _} <- set_coordinators(target_mode, surviving),
         :ok <- exclude_nodes(nodes_to_remove, state) do
      {:reply, {:ok, nodes_to_remove}, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_locked({:call, _from}, {:scale_up, target_mode, nodes_to_add}, state) do
    with :ok <- include_nodes(nodes_to_add, state),
         {:ok, _} <- fdbcli_exec(["coordinators", "auto"]),
         {:ok, _} <- fdbcli_configure_with_retry(target_mode) do
      {:reply, :ok, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_locked({:call, _from}, {:set_redundancy_mode, target_mode}, state) do
    current = current_redundancy_mode()

    if @mode_order[current] >= @mode_order[target_mode] do
      Logger.notice("#{node()} redundancy already #{current}, skipping #{target_mode}")
      {:reply, :ok, state}
    else
      with {:ok, _} <- fdbcli_exec(["coordinators", "auto"]),
           {:ok, _} <- fdbcli_configure_with_retry(target_mode) do
        {:reply, :ok, state}
      else
        {:error, _} = error -> {:reply, error, state}
      end
    end
  end

  # --- Private helpers ---

  defp validate_mode(mode) when mode in @valid_modes, do: :ok
  defp validate_mode(mode), do: {:error, {:invalid_mode, mode}}

  defp validate_known_nodes(nodes, state) do
    unknown = Enum.reject(nodes, &Map.has_key?(state.nodes, &1))

    case unknown do
      [] -> :ok
      _ -> {:error, {:unknown_nodes, unknown}}
    end
  end

  defp validate_min_nodes(mode, nodes) do
    min = @min_nodes[mode]

    if length(nodes) >= min do
      :ok
    else
      {:error, {:insufficient_nodes, mode, length(nodes), min}}
    end
  end

  defp current_redundancy_mode do
    case ExFdbmonitor.Fdbcli.exec(["status", "json"]) do
      {:ok, [stdout: stdout]} ->
        output = IO.iodata_to_binary(stdout)
        status = JSON.decode!(output)
        get_in(status, ["cluster", "configuration", "redundancy_mode"])

      _ ->
        nil
    end
  end

  defp fdbcli_exec(args) do
    Logger.notice("#{node()} fdbcli server exec #{inspect(args)}")
    ExFdbmonitor.Fdbcli.exec(args)
  end

  # fdbserver processes may not be visible to the cluster immediately after
  # include. Retry configure up to 10 times with a 2s delay.
  defp fdbcli_configure_with_retry(mode, attempts \\ 10) do
    case fdbcli_exec(["configure", mode]) do
      {:ok, _} = ok ->
        ok

      {:error, _} = error when attempts <= 1 ->
        error

      {:error, _} ->
        Logger.notice(
          "#{node()} configure #{mode} not ready, retrying in 2s (#{attempts - 1} left)"
        )

        Process.sleep(2_000)
        fdbcli_configure_with_retry(mode, attempts - 1)
    end
  end

  defp set_coordinators(target_mode, nodes) do
    addrs =
      nodes
      |> Enum.flat_map(fn node_name ->
        case :rpc.call(node_name, ExFdbmonitor.Conf, :read_fdbserver_addrs, []) do
          {:badrpc, _} -> []
          addrs -> addrs
        end
      end)

    current = current_coordinators()
    desired_count = @min_nodes[target_mode]
    selected = select_coordinators(addrs, current, desired_count)
    coord_arg = Enum.join(selected, ",")
    fdbcli_exec(["coordinators", coord_arg])
  end

  defp current_coordinators do
    cluster_content = String.trim(ExFdbmonitor.Cluster.read!())
    [_, addr_part] = String.split(cluster_content, "@")
    String.split(addr_part, ",")
  end

  # Prefer existing coordinators that are on surviving nodes, then fill
  # with new addresses to reach the desired count.
  defp select_coordinators(surviving_addrs, current_coords, desired_count) do
    kept = Enum.filter(current_coords, &(&1 in surviving_addrs))
    new = surviving_addrs -- kept

    Enum.take(kept ++ new, desired_count)
  end

  defp exclude_nodes(nodes, state) do
    Enum.reduce_while(nodes, :ok, fn node_name, :ok ->
      machine_id = state.nodes[node_name]

      case fdbcli_exec(["exclude", "locality_machineid:#{machine_id}"]) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp include_nodes(nodes, state) do
    Enum.reduce_while(nodes, :ok, fn node_name, :ok ->
      machine_id = state.nodes[node_name]

      case fdbcli_exec(["include", "locality_machineid:#{machine_id}"]) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
