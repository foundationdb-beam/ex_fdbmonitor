defmodule ExFdbmonitor.Worker do
  @moduledoc false
  defp fdbmonitor(),
    do: Application.get_env(:ex_fdbmonitor, :fdbmonitor, "/usr/local/libexec/fdbmonitor")

  def child_spec(init_arg) do
    default = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]}
    }

    Supervisor.child_spec(default, [])
  end

  def start_link(_arg) do
    etc_dir = Application.fetch_env!(:ex_fdbmonitor, :etc_dir)
    run_dir = Application.fetch_env!(:ex_fdbmonitor, :run_dir)
    conffile = Path.expand(Path.join([etc_dir, "foundationdb.conf"]))
    lockfile = Path.expand(Path.join([run_dir, "FoundationDB.pid"]))

    File.mkdir_p!(Path.dirname(conffile))
    File.mkdir_p!(Path.dirname(lockfile))

    starter = fn ->
      cmd = [fdbmonitor(), "--conffile", conffile, "--lockfile", lockfile]
      {:ok, pid, _os_pid} = :exec.run_link(cmd, [])
      {:ok, pid}
    end

    fetched_bootstrap_config = Application.fetch_env(:ex_fdbmonitor, :bootstrap)

    if bootstrap_safe?(conffile, fetched_bootstrap_config) do
      {:ok, bootstrap_config} = fetched_bootstrap_config

      bootstrap!(starter, bootstrap_config, etc_dir: etc_dir, conffile: conffile)
    else
      cluster_file = ExFdbmonitor.Cluster.file(etc_dir)
      :ok = ensure_mgmt_server(cluster_file)
      starter.()
    end
  end

  defp bootstrap_safe?(_conffile, :error), do: false

  defp bootstrap_safe?(conffile, {:ok, bootstrap_config}) do
    data_dir = Path.expand(bootstrap_config[:conf][:data_dir])

    # We refuse to overwrite the conffile and anything in the data_dir
    conffile_exists? = not File.exists?(conffile)

    data_dir_empty? =
      not File.exists?(data_dir) or
        File.ls!(data_dir) == []

    conffile_exists? and data_dir_empty?
  end

  defp bootstrap!(starter, bootstrap_config, run_config) do
    etc_dir = run_config[:etc_dir]

    fdbservers = bootstrap_config[:conf][:fdbservers]

    cluster_file =
      case bootstrap_config[:cluster] do
        :autojoin ->
          nodes = Application.get_env(:ex_fdbmonitor, :nodes, :erlang.nodes())
          :ok = ExFdbmonitor.autojoin!(nodes)
          ExFdbmonitor.Cluster.file()

        cluster_assigns when is_list(cluster_assigns) ->
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

    conf_assigns = ExFdbmonitor.Conf.assigns(conf_assigns)
    check_config(conf_assigns)
    ExFdbmonitor.Conf.write!(run_config[:conffile], conf_assigns)

    bootstrap_config = Keyword.drop(bootstrap_config, [:cluster, :conf])

    res = {:ok, _pid} = starter.()
    :ok = continue_bootstrap!(bootstrap_config, cluster_file)
    :ok = register_node(cluster_file, resolved[:machine_id])
    res
  end

  defp continue_bootstrap!([], _cluster_file) do
    :ok
  end

  defp continue_bootstrap!([{:fdbcli, nil} | rest], cluster_file) do
    continue_bootstrap!(rest, cluster_file)
  end

  defp continue_bootstrap!([{:fdbcli, ["configure", "new" | _] = exec} | rest], cluster_file) do
    Logger.notice("#{node()} fdbcli local exec #{inspect(exec)}")
    {:ok, [stdout: _]} = ExFdbmonitor.Fdbcli.exec(exec)
    continue_bootstrap!(rest, cluster_file)
  end

  defp continue_bootstrap!([{:fdbcli, exec} | rest], cluster_file) do
    :ok = ensure_mgmt_server(cluster_file)
    {:ok, [stdout: _]} = ExFdbmonitor.MgmtServer.exec(exec)
    continue_bootstrap!(rest, cluster_file)
  end

  defp register_node(cluster_file, machine_id) do
    :ok = ensure_mgmt_server(cluster_file)
    :ok = ExFdbmonitor.MgmtServer.register_node(machine_id, node())
  end

  defp ensure_mgmt_server(cluster_file) do
    case GenServer.whereis(ExFdbmonitor.MgmtServer) do
      pid when is_pid(pid) ->
        :ok

      nil ->
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

  defp check_config(_conf_assigns) do
    check_config? = Application.get_env(:ex_fdbmonitor, :check_config, true)

    if check_config? do
      start_os_mon()

      system_memory_data = :memsup.get_system_memory_data()
      system_total_memory = system_memory_data[:system_total_memory]

      system_memory_threshold_GB = 8

      if system_total_memory < system_memory_threshold_GB * 1_000_000_000 do
        Logger.warning("""
        System memory is less than #{system_memory_threshold_GB}GB. \
        FoundationDB is tuned for systems that can allocate #{system_memory_threshold_GB}GB of system memory per core/disk.
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
