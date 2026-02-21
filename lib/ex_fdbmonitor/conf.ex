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

  def write!(conffile, assigns) do
    {content, resolved} = render(assigns)
    File.write!(conffile, content)

    {conffile, resolved}
  end

  def render(assigns) do
    eex_file = Path.join([:code.priv_dir(:ex_fdbmonitor), @foundationdb_conf_eex])

    EEx.eval_file(eex_file, assigns: assigns)
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
end
