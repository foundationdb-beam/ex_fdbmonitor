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
        {cluster_file, machine_id, fdbcli_cmds} = prepare_files(etc_dir)

        [
          {DynamicSupervisor, name: ExFdbmonitor.DynamicSupervisor, strategy: :one_for_one},
          {ExFdbmonitor.Worker, []},
          # Phase 2: run fdbcli commands and start MgmtServer (requires Worker running)
          %{
            id: :setup_cluster,
            start: {__MODULE__, :setup_cluster, [cluster_file, fdbcli_cmds, machine_id]},
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
      {{ok, _}, {ok, _}} ->
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
  # Returns {cluster_file, machine_id, fdbcli_cmds} where fdbcli_cmds
  # are deferred to phase 2 since they require a running fdbserver.
  defp prepare_files(etc_dir) do
    conffile = Path.expand(Path.join([etc_dir, "foundationdb.conf"]))

    File.mkdir_p!(Path.dirname(conffile))

    fetched_bootstrap_config = Application.fetch_env(:ex_fdbmonitor, :bootstrap)

    if bootstrap_safe?(conffile, fetched_bootstrap_config) do
      {:ok, bootstrap_config} = fetched_bootstrap_config

      write_bootstrap_files(bootstrap_config, etc_dir, conffile)
    else
      cluster_file = ExFdbmonitor.Cluster.file(etc_dir)
      {cluster_file, nil, []}
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

    {_conffile, resolved} = ExFdbmonitor.Conf.write!(conffile, conf_assigns)

    fdbcli_cmds =
      bootstrap_config
      |> Keyword.get_values(:fdbcli)
      |> Enum.reject(&is_nil/1)

    {cluster_file, resolved[:machine_id], fdbcli_cmds}
  end

  # Phase 2: run fdbcli commands and start MgmtServer.
  # Called as a child start function after Worker is running.
  # Returns :ignore so the supervisor treats this as a completed one-shot.
  @doc false
  def setup_cluster(cluster_file, fdbcli_cmds, machine_id) do
    for cmd <- fdbcli_cmds do
      case cmd do
        ["configure", "new" | _] ->
          Logger.notice("#{node()} fdbcli local exec #{inspect(cmd)}")
          {:ok, [stdout: _]} = ExFdbmonitor.Fdbcli.exec(cmd)

        _ ->
          ensure_mgmt_server(cluster_file)
          {:ok, [stdout: _]} = ExFdbmonitor.MgmtServer.exec(cmd)
      end
    end

    ensure_mgmt_server(cluster_file)

    if machine_id do
      :ok = ExFdbmonitor.MgmtServer.register_node(machine_id, node())
    end

    :ignore
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
end
