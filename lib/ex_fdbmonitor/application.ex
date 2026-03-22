require Logger

defmodule ExFdbmonitor.Application do
  @moduledoc false

  use Application

  alias ExFdbmonitor.Bootstrap

  @impl true
  def start(_type, _args) do
    {children, bootstrap} =
      if worker?() do
        etc_dir = Application.fetch_env!(:ex_fdbmonitor, :etc_dir)

        # Phase 1: write config files before any processes start
        %Bootstrap{} = bootstrap = prepare_files(etc_dir)

        children = [
          {DynamicSupervisor, name: ExFdbmonitor.DynamicSupervisor, strategy: :one_for_one},
          {ExFdbmonitor.Worker, []},
          {ExFdbmonitor.SetupCluster, bootstrap}
        ]

        {children, bootstrap}
      else
        {[], nil}
      end

    # Use rest_for_one: if Worker dies, SetupCluster is terminated and
    # restarted so it retries setup against the fresh Worker.
    opts = [strategy: :rest_for_one, name: ExFdbmonitor.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)

    # Block until cluster setup is complete. The supervisor is alive and
    # can restart Worker if it crashes. If Worker keeps crashing, the
    # supervisor hits max_restart_intensity, crashes, and this call
    # propagates the error — failing application startup.
    if bootstrap do
      :ok = ExFdbmonitor.SetupCluster.await()
    end

    {:ok, sup}
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
  # Returns a %Bootstrap{} struct. fdbcli_cmds and redundancy_mode are
  # deferred to phase 2 since they require a running fdbserver.
  defp prepare_files(etc_dir) do
    conffile = Path.expand(Path.join([etc_dir, "foundationdb.conf"]))

    File.mkdir_p!(Path.dirname(conffile))

    fetched_bootstrap_config = Application.fetch_env(:ex_fdbmonitor, :bootstrap)

    if bootstrap_safe?(conffile, fetched_bootstrap_config) do
      {:ok, bootstrap_config} = fetched_bootstrap_config

      write_bootstrap_files(bootstrap_config, etc_dir, conffile)
    else
      cluster_file = ExFdbmonitor.Cluster.file(etc_dir)
      %Bootstrap{cluster_file: cluster_file}
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
    fdbserver_ports = Enum.map(fdbservers, & &1[:port])

    %Bootstrap{
      cluster_file: cluster_file,
      machine_id: resolved[:machine_id],
      fdbcli_cmds: fdbcli_cmds,
      redundancy_mode: redundancy_mode,
      fdbserver_ports: fdbserver_ports
    }
  end

  defp fdb_node?(node) do
    case :rpc.call(node, Application, :started_applications, []) do
      {:badrpc, _} -> false
      apps -> not is_nil(List.keyfind(apps, :ex_fdbmonitor, 0))
    end
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
end
