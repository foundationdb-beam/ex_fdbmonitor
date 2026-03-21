require Logger

defmodule ExFdbmonitor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if worker?() do
        etc_dir = Application.fetch_env!(:ex_fdbmonitor, :etc_dir)

        # Phase 1: write config files before any processes start
        {cluster_file, machine_id, fdbcli_cmds, redundancy_mode} = prepare_files(etc_dir)

        [
          {DynamicSupervisor, name: ExFdbmonitor.DynamicSupervisor, strategy: :one_for_one},
          {ExFdbmonitor.Worker, []},
          # Phase 2: run fdbcli commands and start MgmtServer (requires Worker running)
          %{
            id: :setup_cluster,
            start:
              {__MODULE__, :setup_cluster,
               [cluster_file, fdbcli_cmds, machine_id, redundancy_mode]},
            restart: :temporary
          }
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: ExFdbmonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp worker?() do
    case {Application.fetch_env(:ex_fdbmonitor, :etc_dir),
          Application.fetch_env(:ex_fdbmonitor, :run_dir)} do
      {{:ok, _}, {:ok, _}} ->
        true

      _ ->
        Logger.warning("""
        ExFdbmonitor starting without running fdbmonitor. At minimum, you \
        should define `:etc_dir` and `:run_dir`, but you should also consider \
        adding a `:bootstrap` config.
        """)

        false
    end
  end

  # Phase 1: prepare all files on disk (cluster file, conffile, dirs).
  # Returns {cluster_file, machine_id, fdbcli_cmds, redundancy_mode} where
  # fdbcli_cmds and redundancy_mode are deferred to phase 2 since they
  # require a running fdbserver.
  defp prepare_files(etc_dir) do
    conffile = Path.expand(Path.join([etc_dir, "foundationdb.conf"]))

    File.mkdir_p!(Path.dirname(conffile))

    fetched_bootstrap_config = Application.fetch_env(:ex_fdbmonitor, :bootstrap)

    if bootstrap_safe?(conffile, fetched_bootstrap_config) do
      {:ok, bootstrap_config} = fetched_bootstrap_config

      write_bootstrap_files(bootstrap_config, etc_dir, conffile)
    else
      cluster_file = ExFdbmonitor.Cluster.file(etc_dir)
      {cluster_file, nil, [], nil}
    end
  end

  defp bootstrap_safe?(_conffile, :error), do: false

  defp bootstrap_safe?(conffile, {:ok, bootstrap_config}) do
    data_dir = Path.expand(bootstrap_config[:conf][:data_dir])

    # We refuse to overwrite the conffile and anything in the data_dir
    conffile_missing? = not File.exists?(conffile)

    data_dir_empty? =
      not File.exists?(data_dir) or
        File.ls!(data_dir) == []

    conffile_missing? and data_dir_empty?
  end

  defp write_bootstrap_files(bootstrap_config, etc_dir, conffile) do
    fdbservers = bootstrap_config[:conf][:fdbservers]
    cluster_assigns = bootstrap_config[:cluster] || []

    nodes = Application.get_env(:ex_fdbmonitor, :nodes, :erlang.nodes())
    fdb_peers = Enum.filter(nodes, &fdb_node?/1)

    cluster_file =
      if fdb_peers != [] do
        :ok = ExFdbmonitor.Cluster.join!(fdb_peers)
        ExFdbmonitor.Cluster.file()
      else
        cluster_assigns =
          Keyword.merge(cluster_assigns, coordinator_port: hd(fdbservers)[:port])

        ExFdbmonitor.Cluster.write!(etc_dir, cluster_assigns)
      end

    data_dir = Path.expand(bootstrap_config[:conf][:data_dir])
    log_dir = Path.expand(bootstrap_config[:conf][:log_dir])
    File.mkdir_p!(data_dir)
    File.mkdir_p!(log_dir)

    conf_assigns =
      bootstrap_config[:conf]
      |> Keyword.merge(data_dir: data_dir, log_dir: log_dir, cluster_file: cluster_file)

    {_conffile, resolved} = ExFdbmonitor.Conf.write!(conffile, conf_assigns)
    check_config()

    storage_engine = bootstrap_config[:conf][:storage_engine] || "ssd-2"

    fdbcli_cmds =
      if fdb_peers == [] do
        [["configure", "new", "single", storage_engine]]
      else
        []
      end

    explicit_cmds =
      bootstrap_config
      |> Keyword.get_values(:fdbcli)
      |> Enum.reject(&is_nil/1)

    fdbcli_cmds = fdbcli_cmds ++ explicit_cmds

    redundancy_mode = bootstrap_config[:conf][:redundancy_mode]

    {cluster_file, resolved[:machine_id], fdbcli_cmds, redundancy_mode}
  end

  defp fdb_node?(node) do
    case :rpc.call(node, Application, :started_applications, []) do
      {:badrpc, _} -> false
      apps -> not is_nil(List.keyfind(apps, :ex_fdbmonitor, 0))
    end
  end

  # Phase 2: run fdbcli commands, register node, and optionally set redundancy mode.
  # Called as a child start function after Worker is running.
  # Returns :ignore so the supervisor treats this as a completed one-shot.
  @doc false
  def setup_cluster(cluster_file, fdbcli_cmds, machine_id, redundancy_mode) do
    case wait_for_fdbserver() do
      :ok -> :ok
      :timeout ->
        # fdbserver never appeared — dump diagnostics
        {pgrep_mon, _} = System.cmd("pgrep", ["-a", "fdbmonitor"], stderr_to_stdout: true)
        Logger.notice("#{node()} pgrep fdbmonitor: #{String.trim(pgrep_mon)}")

        {pgrep_srv, _} = System.cmd("pgrep", ["-a", "fdbserver"], stderr_to_stdout: true)
        Logger.notice("#{node()} pgrep fdbserver: #{String.trim(pgrep_srv)}")

        # Try running fdbmonitor directly to see what happens
        fdbmonitor_path = ExFdbmonitor.Binaries.fdbmonitor()
        {test_output, test_exit} = System.cmd(fdbmonitor_path, ["--help"], stderr_to_stdout: true)
        Logger.notice("#{node()} fdbmonitor --help exit=#{test_exit}: #{String.trim(test_output)}")

        # Check file permissions
        {ls_output, _} = System.cmd("ls", ["-la", fdbmonitor_path], stderr_to_stdout: true)
        Logger.notice("#{node()} fdbmonitor permissions: #{String.trim(ls_output)}")

        # Check what user we're running as
        {whoami, _} = System.cmd("whoami", [], stderr_to_stdout: true)
        Logger.notice("#{node()} running as user: #{String.trim(whoami)}")

        log_dir = Application.get_env(:ex_fdbmonitor, :bootstrap)[:conf][:log_dir]
        if log_dir do
          case File.ls(log_dir) do
            {:ok, files} ->
              Logger.notice("#{node()} log_dir contents: #{inspect(files)}")
              for f <- files do
                content = File.read!(Path.join(log_dir, f))
                Logger.notice("#{node()} log file #{f}:\n#{String.slice(content, 0, 2000)}")
              end
            {:error, reason} ->
              Logger.notice("#{node()} log_dir #{log_dir} error: #{inspect(reason)}")
          end
        end

        raise "fdbserver did not start within 10000ms. Check fdbmonitor logs."
    end

    for cmd <- fdbcli_cmds do
      case cmd do
        ["configure", "new" | _] ->
          Logger.notice("#{node()} fdbcli local exec #{inspect(cmd)}")
          result = ExFdbmonitor.Fdbcli.exec(cluster_file, cmd)
          Logger.notice("#{node()} fdbcli local result #{inspect(result)}")
          {:ok, [stdout: _]} = result

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

    :ignore
  end

  defp check_config() do
    check_config? = Application.get_env(:ex_fdbmonitor, :check_config, true)

    if check_config? do
      start_os_mon()

      system_memory_data = :memsup.get_system_memory_data()
      system_total_memory = system_memory_data[:system_total_memory]

      system_memory_threshold_gb = 8

      if system_total_memory < system_memory_threshold_gb * 1_000_000_000 do
        Logger.warning("""
        System memory is less than #{system_memory_threshold_gb}GB. \
        FoundationDB is tuned for systems that can allocate #{system_memory_threshold_gb}GB of system memory per core/disk.
        """)
      end
    end
  end

  defp start_os_mon() do
    already_started? =
      :application.which_applications()
      |> then(&:lists.keyfind(:os_mon, 1, &1))
      |> is_tuple()

    if !already_started? do
      :application.load(:os_mon)

      [
        disk_almost_full_threshold: 1.0,
        system_memory_high_watermark: 1.0,
        process_memory_high_watermark: 1.0
      ]
      |> Enum.each(&:application.set_env(:os_mon, elem(&1, 0), elem(&1, 1)))

      {:ok, _} = :application.ensure_all_started(:os_mon)
    end

    !already_started?
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

  # Wait for fdbmonitor to spawn at least one fdbserver process.
  # fdbmonitor forks fdbserver asynchronously after start_link returns,
  # so on slower systems (e.g. CI) setup_cluster can run before the
  # fdbserver process exists.
  defp wait_for_fdbserver(retries \\ 50, interval_ms \\ 200) do
    {output, _} = System.cmd("pgrep", ["-x", "fdbserver"], stderr_to_stdout: true)

    cond do
      String.trim(output) != "" ->
        Logger.notice("#{node()} fdbserver is running")
        :ok

      retries > 0 ->
        Process.sleep(interval_ms)
        wait_for_fdbserver(retries - 1, interval_ms)

      true ->
        :timeout
    end
  end

  # Poll `fdbcli status json` until client.database_status.available is true,
  # or until we exhaust retries. Each probe gives fdbcli up to 10 s to connect
  # (-t 10); fdbcli always emits valid JSON even when the cluster is down, so
  # we parse the output rather than relying solely on the exit code.
  defp wait_for_database(cluster_file, retries \\ 30, interval_ms \\ 2_000) do
    available? =
      case ExFdbmonitor.Fdbcli.exec(cluster_file, ["status", "json"],
             timeout: 10_000,
             stderr: false
           ) do
        {_, props} ->
          stdout = props |> Keyword.get(:stdout, []) |> IO.iodata_to_binary()
          decoded = JSON.decode(stdout)
          available = match?({:ok, %{"client" => %{"database_status" => %{"available" => true}}}}, decoded)
          Logger.notice("#{node()} status json available=#{available} decoded=#{inspect(decoded, limit: 5)}")
          available

        other ->
          Logger.notice("#{node()} status json unexpected result: #{inspect(other, limit: 5)}")
          false
      end

    cond do
      available? ->
        :ok

      retries > 0 ->
        Logger.notice("#{node()} waiting for FDB cluster to become available (#{retries} retries left)...")
        Process.sleep(interval_ms)
        wait_for_database(cluster_file, retries - 1, interval_ms)

      true ->
        raise "FDB cluster at #{cluster_file} did not become available."
    end
  end
end
