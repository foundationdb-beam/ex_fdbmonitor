defmodule ExFdbmonitor.Worker do
  @moduledoc false
  defp fdbmonitor(), do: ExFdbmonitor.Binaries.fdbmonitor()

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

    fdbmonitor_bin = fdbmonitor()

    if !File.exists?(fdbmonitor_bin) do
      raise "fdbmonitor binary not found at #{fdbmonitor_bin}"
    end

    cmd =
      [fdbmonitor_bin, "--conffile", conffile, "--lockfile", lockfile]
      |> Enum.map(&String.to_charlist/1)

    {:ok, pid, _os_pid} = :exec.run_link(cmd, [])
    {:ok, pid}
  end
end
