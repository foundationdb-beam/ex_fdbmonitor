defmodule ExFdbmonitor.Worker do
  @moduledoc false
  require Logger
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

    cmd = [fdbmonitor_bin, "--conffile", conffile, "--lockfile", lockfile]
    Logger.notice("#{node()} starting fdbmonitor: #{inspect(cmd)}")

    {:ok, pid, os_pid} =
      :exec.run_link(cmd, [
        {:stdout, self()},
        {:stderr, self()}
      ])

    Logger.notice("#{node()} fdbmonitor started pid=#{inspect(pid)} os_pid=#{os_pid}")

    # Drain any early output from fdbmonitor so we can see errors in the log
    spawn(fn -> drain_fdbmonitor_output(os_pid) end)

    {:ok, pid}
  end

  defp drain_fdbmonitor_output(os_pid) do
    receive do
      {:stdout, ^os_pid, data} ->
        Logger.notice("fdbmonitor stdout: #{data}")
        drain_fdbmonitor_output(os_pid)

      {:stderr, ^os_pid, data} ->
        Logger.notice("fdbmonitor stderr: #{data}")
        drain_fdbmonitor_output(os_pid)
    after
      15_000 -> :ok
    end
  end
end
