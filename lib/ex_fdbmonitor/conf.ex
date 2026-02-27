defmodule ExFdbmonitor.Conf do
  @moduledoc false
  @foundationdb_conf_eex "foundationdb.conf.eex"
  defp fdbserver(),
    do: Application.get_env(:ex_fdbmonitor, :fdbserver, "/usr/local/libexec/fdbserver")

  defp backup_agent(),
    do:
      Application.get_env(
        :ex_fdbmonitor,
        :backup_agent,
        "/usr/local/foundationdb/backup_agent/backup_agent"
      )

  defp dr_agent(), do: Application.get_env(:ex_fdbmonitor, :dr_agent, "/usr/local/bin/dr_agent")

  def assigns(conf_assigns) do
    Keyword.merge(default_assigns(), conf_assigns)
  end

  def write!(conffile, conf_assigns) do
    resolved = assigns(conf_assigns)
    content = render(resolved)
    File.write!(conffile, content)

    {conffile, resolved}
  end

  def render(resolved_assigns) do
    eex_file = Path.join([:code.priv_dir(:ex_fdbmonitor), @foundationdb_conf_eex])

    EEx.eval_file(eex_file, assigns: resolved_assigns)
  end

  defp default_assigns() do
    [
      fdbserver: fdbserver(),
      backup_agent: backup_agent(),
      dr_agent: dr_agent(),
      class: nil,
      machine_id: Base.encode16(:crypto.strong_rand_bytes(4)),
      data_hall: nil,
      datacenter_id: nil,
      memory: nil,
      memory_vsize: nil,
      cache_memory: nil,
      storage_memory: nil,
      backup: nil,
      dr: nil
    ]
  end

  @doc """
  Read the fdbserver addresses from this node's foundationdb.conf and cluster file.

  Parses `[fdbserver.PORT]` sections from the conf file and extracts the IP
  from the cluster file. Returns a list of `"ip:port"` strings.
  """
  def read_fdbserver_addrs do
    etc_dir = Application.fetch_env!(:ex_fdbmonitor, :etc_dir)
    conffile = Path.expand(Path.join([etc_dir, "foundationdb.conf"]))
    content = File.read!(conffile)

    ports =
      Regex.scan(~r/\[fdbserver\.(\d+)\]/, content)
      |> Enum.map(fn [_, port] -> port end)

    cluster_content = String.trim(ExFdbmonitor.Cluster.read!())
    [_, addr_part] = String.split(cluster_content, "@")
    [ip, _port] = String.split(hd(String.split(addr_part, ",")), ":")

    Enum.map(ports, fn port -> "#{ip}:#{port}" end)
  end
end
