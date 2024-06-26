defmodule ExFdbmonitor.Conf do
  @foundationdb_conf_eex "foundationdb.conf.eex"
  @fdbserver "/usr/local/libexec/fdbserver"
  @backup_agent "/usr/local/foundationdb/backup_agent/backup_agent"
  @dr_agent "/usr/local/bin/dr_agent"

  def write!(conffile, assigns) do
    File.write!(conffile, ExFdbmonitor.Conf.render(assigns))

    conffile
  end

  def render(assigns) do
    eex_file = Path.join([:code.priv_dir(:ex_fdbmonitor), @foundationdb_conf_eex])

    EEx.eval_file(eex_file,
      assigns:
        Keyword.merge(
          [
            fdbserver: @fdbserver,
            backup_agent: @backup_agent,
            dr_agent: @dr_agent,
            class: nil,
            machine_id: Base.encode16(:crypto.strong_rand_bytes(4)),
            data_hall: nil,
            datacenter_id: nil,
            backup: nil,
            dr: nil
          ],
          assigns
        )
    )
  end
end
