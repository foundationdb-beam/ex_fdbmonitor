require Logger

defmodule ExFdbmonitor.Worker do
  @moduledoc false
  @fdbmonitor "/usr/local/libexec/fdbmonitor"

  def child_spec(init_arg) do
    default = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]}
    }

    Supervisor.child_spec(default, [])
  end

  # https://github.com/apple/foundationdb/blob/main/packaging/osx/com.foundationdb.fdbmonitor.plist
  # <array>
  #   <string>/usr/local/libexec/fdbmonitor</string>
  #   <string>--conffile</string>
  #   <string>/usr/local/etc/foundationdb/foundationdb.conf</string>
  #   <string>--lockfile</string>
  #   <string>/var/run/FoundationDB.pid</string>
  # </array>
  def start_link(_arg) do
    etc_dir = Application.fetch_env!(:ex_fdbmonitor, :etc_dir)
    run_dir = Application.fetch_env!(:ex_fdbmonitor, :run_dir)
    conffile = Path.expand(Path.join([etc_dir, "foundationdb.conf"]))
    lockfile = Path.expand(Path.join([run_dir, "FoundationDB.pid"]))

    File.mkdir_p!(Path.dirname(conffile))
    File.mkdir_p!(Path.dirname(lockfile))

    starter = fn ->
      cmd = [@fdbmonitor, "--conffile", conffile, "--lockfile", lockfile]
      {:ok, pid, _os_pid} = :exec.run_link(cmd, [])
      {:ok, pid}
    end

    fetched_bootstrap_config = Application.fetch_env(:ex_fdbmonitor, :bootstrap)

    if bootstrap_safe?(conffile, fetched_bootstrap_config) do
      {:ok, bootstrap_config} = fetched_bootstrap_config

      bootstrap!(starter, bootstrap_config, etc_dir: etc_dir, conffile: conffile)
    else
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

    ExFdbmonitor.Conf.write!(run_config[:conffile], conf_assigns)

    bootstrap_config = Keyword.drop(bootstrap_config, [:cluster, :conf])

    res = {:ok, _pid} = starter.()
    :ok = continue_bootstrap!(bootstrap_config)
    res
  end

  def continue_bootstrap!([]) do
    :ok
  end

  def continue_bootstrap!([{:fdbcli, nil} | rest]) do
    continue_bootstrap!(rest)
  end

  def continue_bootstrap!([{:fdbcli, exec} | rest]) do
    # Absence of stderr implies success
    Logger.notice("#{node()} fdbcli exec #{inspect(exec)}")

    {:ok, [stdout: _]} =
      ExFdbmonitor.Fdbcli.exec(exec)

    continue_bootstrap!(rest)
  end
end
