require Logger

defmodule ExFdbmonitor.SetupCluster do
  @moduledoc false

  use GenServer

  alias ExFdbmonitor.Bootstrap

  def start_link(%Bootstrap{} = bootstrap) do
    GenServer.start_link(__MODULE__, bootstrap, name: __MODULE__)
  end

  @doc """
  Block until cluster setup is complete. Returns `:ok` on success.

  If the SetupCluster process crashes (e.g. because Worker keeps dying and
  the supervisor shuts down), the caller receives an exit signal.
  """
  def await do
    GenServer.call(__MODULE__, :await, :infinity)
  end

  # -------------------------------------------------------------------
  # Callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(%Bootstrap{} = bootstrap) do
    {:ok, %{bootstrap: bootstrap, ready: false, waiting: []}, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    run_setup(state.bootstrap)
    replies = Enum.map(state.waiting, fn from -> {from, :ok} end)

    {:noreply, %{state | ready: true, waiting: []}, {:continue, {:reply_waiting, replies}}}
  end

  def handle_continue({:reply_waiting, []}, state) do
    {:noreply, state}
  end

  def handle_continue({:reply_waiting, [{from, reply} | rest]}, state) do
    GenServer.reply(from, reply)
    {:noreply, state, {:continue, {:reply_waiting, rest}}}
  end

  @impl true
  def handle_call(:await, _from, %{ready: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await, from, %{ready: false} = state) do
    {:noreply, %{state | waiting: [from | state.waiting]}}
  end

  # -------------------------------------------------------------------
  # Setup logic (moved from Application.setup_cluster)
  # -------------------------------------------------------------------

  defp run_setup(%Bootstrap{} = bootstrap) do
    %Bootstrap{
      cluster_file: cluster_file,
      machine_id: machine_id,
      fdbcli_cmds: fdbcli_cmds,
      redundancy_mode: redundancy_mode,
      fdbserver_ports: fdbserver_ports
    } = bootstrap

    wait_for_fdbserver(fdbserver_ports)

    for cmd <- fdbcli_cmds do
      case cmd do
        ["configure", "new" | _] ->
          Logger.notice("#{node()} fdbcli local exec #{inspect(cmd)}")
          {:ok, [stdout: _]} = ExFdbmonitor.Fdbcli.exec(cluster_file, cmd)

        _ ->
          ensure_mgmt_server(cluster_file)
          {:ok, [stdout: _]} = ExFdbmonitor.MgmtServer.exec(cmd)
      end
    end

    ensure_mgmt_server(cluster_file)

    if machine_id do
      :ok = ExFdbmonitor.MgmtServer.register_node(machine_id, node())
    end

    case ExFdbmonitor.MgmtServer.scale_up(redundancy_mode, [node()]) do
      :ok ->
        :ok

      {:error, {:unknown_nodes, nodes}} ->
        raise """
        Node #{inspect(hd(nodes))} is not registered in MgmtServer. \
        This usually means either the initial bootstrap did not complete \
        successfully, or the node name changed since the first boot. \
        Clear the data directory and restart to re-bootstrap, or ensure \
        the node is started with the same name it was originally registered with.\
        """
    end
  end

  defp ensure_mgmt_server(cluster_file) do
    case GenServer.whereis(ExFdbmonitor.MgmtServer) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        :ok = wait_for_database(cluster_file)
        db = :erlfdb.open(cluster_file)
        root = :erlfdb_directory.root()
        dir_name = Application.get_env(:ex_fdbmonitor, :dir, "ex_fdbmonitor")
        dir = :erlfdb_directory.create_or_open(db, root, dir_name)

        {:ok, _} =
          DynamicSupervisor.start_child(
            ExFdbmonitor.DynamicSupervisor,
            {ExFdbmonitor.MgmtServer, {db, dir}}
          )

        :ok
    end
  end

  # Wait for at least one fdbserver to accept TCP connections. fdbmonitor
  # spawns fdbserver asynchronously after Worker.start_link returns, so on
  # slower systems (e.g. CI) the server may not be listening yet when
  # setup runs.
  defp wait_for_fdbserver(ports, retries \\ 50, interval_ms \\ 200)
  defp wait_for_fdbserver([], _retries, _interval_ms), do: :ok

  defp wait_for_fdbserver(ports, retries, interval_ms) do
    connected? =
      Enum.any?(ports, fn port ->
        case :gen_tcp.connect({127, 0, 0, 1}, port, [], 500) do
          {:ok, sock} ->
            :gen_tcp.close(sock)
            true

          {:error, _} ->
            false
        end
      end)

    cond do
      connected? ->
        :ok

      retries > 0 ->
        Process.sleep(interval_ms)
        wait_for_fdbserver(ports, retries - 1, interval_ms)

      true ->
        raise "fdbserver not reachable on any of ports #{inspect(ports)} within 10s"
    end
  end

  # Poll `fdbcli status json` until client.database_status.available is true,
  # or until we exhaust retries.
  defp wait_for_database(cluster_file, retries \\ 30, interval_ms \\ 2_000) do
    available? =
      case ExFdbmonitor.Fdbcli.exec(cluster_file, ["status", "json"],
             timeout: 10_000,
             stderr: false
           ) do
        {_, props} ->
          stdout = props |> Keyword.get(:stdout, []) |> IO.iodata_to_binary()

          match?(
            {:ok, %{"client" => %{"database_status" => %{"available" => true}}}},
            JSON.decode(stdout)
          )

        _ ->
          false
      end

    cond do
      available? ->
        :ok

      retries > 0 ->
        Logger.debug("#{node()} waiting for FDB cluster to become available...")
        Process.sleep(interval_ms)
        wait_for_database(cluster_file, retries - 1, interval_ms)

      true ->
        raise "FDB cluster at #{cluster_file} did not become available."
    end
  end
end
