require Logger

defmodule ExFdbmonitor.MgmtServer do
  @moduledoc """
  A DGenServer that serializes actions across all nodes.

  Nodes submit fdbcli commands via `exec/1`. The DGenServer processes
  them one at a time, ensuring commands from different nodes don't
  interleave on a cluster that is still being configured.
  """

  use DGenServer

  defstruct nodes: %{}, redundancy_mode: nil

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
  Gracefully remove `nodes_to_exclude` from the cluster.

  Automatically determines the appropriate redundancy mode for the
  surviving nodes and downgrades if necessary. Executes under the
  DGenServer lock:
  1. `configure <mode>` (only if downgrade needed)
  2. Set coordinators to surviving nodes
  3. `exclude` each departing node (blocks until data moved)

  The caller is responsible for stopping workers on the removed nodes
  after this call returns.
  """
  def scale_down(nodes_to_exclude) do
    DGenServer.call(__MODULE__, {:scale_down, nodes_to_exclude}, :infinity)
  end

  @doc """
  Declare the desired redundancy mode and configure when ready.

  When `target_mode` is non-nil it is stored as the redundancy ceiling.
  When `target_mode` is nil the previously stored mode is used (also
  nil is fine — the call becomes a no-op).

  `nodes_to_include` is a list of node names to `include` back into FDB
  before configuring (e.g. after a previous `exclude`).

  If enough nodes are registered (`@min_nodes`), acquires the lock and
  runs `include` → `coordinators auto` → `configure <mode>`.  Calls
  before the threshold is met are no-ops.
  """
  def scale_up(target_mode, nodes_to_include) do
    DGenServer.call(__MODULE__, {:scale_up, target_mode, nodes_to_include}, :infinity)
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

  def handle_call({:scale_down, nodes_to_exclude}, _from, state) do
    with :ok <- validate_known_nodes(nodes_to_exclude, state),
         surviving = Map.keys(state.nodes) -- nodes_to_exclude,
         :ok <- validate_has_survivors(surviving) do
      {:lock, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:scale_up, target_mode, nodes_to_include}, _from, state) do
    with :ok <- validate_known_nodes(nodes_to_include, state) do
      {effective_mode, state} =
        if target_mode do
          {target_mode, %{state | redundancy_mode: target_mode}}
        else
          {state.redundancy_mode, state}
        end

      case effective_mode do
        nil ->
          {:reply, :ok, state}

        mode ->
          with :ok <- validate_mode(mode) do
            all_nodes = Map.keys(state.nodes)

            if length(all_nodes) >= @min_nodes[mode] do
              {:lock, state}
            else
              {:reply, :ok, state}
            end
          else
            {:error, _} = error -> {:reply, error, state}
          end
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

  def handle_locked({:call, _from}, {:scale_down, nodes_to_exclude}, state) do
    surviving = Map.keys(state.nodes) -- nodes_to_exclude
    current = current_redundancy_mode()
    target = target_mode(length(surviving), state)

    with {:ok, _} <- maybe_configure(current, target),
         {:ok, _} <- set_coordinators(target, surviving),
         :ok <- exclude_nodes(nodes_to_exclude, state) do
      {:reply, {:ok, nodes_to_exclude}, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_locked({:call, _from}, {:scale_up, _target_mode, nodes_to_include}, state) do
    mode = state.redundancy_mode
    current = current_redundancy_mode()

    with :ok <- include_nodes(nodes_to_include, state),
         {:ok, _} <- fdbcli_exec(["coordinators", "auto"]) do
      if @mode_order[current] >= @mode_order[mode] do
        Logger.notice("#{node()} redundancy already #{current}, skipping #{mode}")
        {:reply, :ok, state}
      else
        case fdbcli_configure_with_retry(mode) do
          {:ok, _} -> {:reply, :ok, state}
          {:error, _} = error -> {:reply, error, state}
        end
      end
    else
      {:error, _} = error -> {:reply, error, state}
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

  defp validate_has_survivors(surviving) do
    if surviving != [], do: :ok, else: {:error, :cannot_remove_all_nodes}
  end

  # The target mode for a given survivor count, capped at the declared
  # redundancy_mode ceiling (if set via scale_up).
  defp target_mode(survivor_count, state) do
    max_supported = max_mode_for_count(survivor_count)

    case state.redundancy_mode do
      nil -> max_supported
      declared -> min_mode(max_supported, declared)
    end
  end

  defp max_mode_for_count(n) when n >= 5, do: "triple"
  defp max_mode_for_count(n) when n >= 3, do: "double"
  defp max_mode_for_count(_n), do: "single"

  defp min_mode(a, b) do
    if @mode_order[a] <= @mode_order[b], do: a, else: b
  end

  # Only reconfigure if the current mode exceeds what survivors can support.
  defp maybe_configure(current, target) do
    if @mode_order[current] > @mode_order[target] do
      fdbcli_exec(["configure", target])
    else
      {:ok, :unchanged}
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

  defp exclude_nodes([], _state), do: :ok

  defp exclude_nodes(nodes, state) do
    args = ["exclude" | locality_args(nodes, state)]

    case fdbcli_exec(args) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp include_nodes([], _state), do: :ok

  defp include_nodes(nodes, state) do
    args = ["include" | locality_args(nodes, state)]

    case fdbcli_exec(args) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp locality_args(nodes, state) do
    Enum.map(nodes, fn node_name ->
      "locality_machineid:#{state.nodes[node_name]}"
    end)
  end
end
