defmodule ExFdbmonitor.Binaries do
  @moduledoc """
  Resolves paths to FoundationDB binaries.

  A path configured via `Application.get_env/3` always takes precedence.
  Otherwise the default for the current OS is used.

  Supported systems: Darwin (macOS) and Linux. Windows is not supported.

  ## Configuration

  Override any binary path in your application config:

      config :ex_fdbmonitor,
        fdbmonitor: "/custom/path/fdbmonitor",
        fdbcli: "/custom/path/fdbcli",
        fdbserver: "/custom/path/fdbserver",
        fdbdr: "/custom/path/fdbdr",
        backup_agent: "/custom/path/backup_agent",
        dr_agent: "/custom/path/dr_agent"

  ## OS defaults

  | Binary | macOS | Linux |
  |--------|-------|-------|
  | `fdbmonitor` | `/usr/local/libexec/fdbmonitor` | `/usr/lib/foundationdb/fdbmonitor` |
  | `fdbcli` | `/usr/local/bin/fdbcli` | `/usr/bin/fdbcli` |
  | `fdbserver` | `/usr/local/libexec/fdbserver` | `/usr/sbin/fdbserver` |
  | `fdbdr` | `/usr/local/bin/fdbdr` | `/usr/bin/fdbdr` |
  | `backup_agent` | `/usr/local/foundationdb/backup_agent/backup_agent` | `/usr/lib/foundationdb/backup_agent/backup_agent` |
  | `dr_agent` | `/usr/local/bin/dr_agent` | `/usr/bin/dr_agent` |
  """

  @darwin %{
    fdbmonitor: "/usr/local/libexec/fdbmonitor",
    fdbcli: "/usr/local/bin/fdbcli",
    fdbserver: "/usr/local/libexec/fdbserver",
    fdbdr: "/usr/local/bin/fdbdr",
    backup_agent: "/usr/local/foundationdb/backup_agent/backup_agent",
    dr_agent: "/usr/local/bin/dr_agent"
  }

  @linux %{
    fdbmonitor: "/usr/lib/foundationdb/fdbmonitor",
    fdbcli: "/usr/bin/fdbcli",
    fdbserver: "/usr/sbin/fdbserver",
    fdbdr: "/usr/bin/fdbdr",
    backup_agent: "/usr/lib/foundationdb/backup_agent/backup_agent",
    dr_agent: "/usr/bin/dr_agent"
  }

  def fdbmonitor, do: resolve(:fdbmonitor)
  def fdbcli, do: resolve(:fdbcli)
  def fdbserver, do: resolve(:fdbserver)
  def fdbdr, do: resolve(:fdbdr)
  def backup_agent, do: resolve(:backup_agent)
  def dr_agent, do: resolve(:dr_agent)

  defp resolve(binary) do
    case Application.get_env(:ex_fdbmonitor, binary) do
      nil -> os_default(binary)
      path -> path
    end
  end

  defp os_default(binary) do
    case :os.type() do
      {:unix, :darwin} -> @darwin[binary]
      {:unix, :linux} -> @linux[binary]
      os -> raise "#{inspect(os)} is not a supported OS"
    end
  end
end
