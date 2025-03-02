defmodule ExFdbmonitor.Fdbcli do
  @moduledoc """
  This module provides functions for executing fdbcli commands.
  """
  defp fdbcli(), do: Application.get_env(:ex_fdbmonitor, :fdbcli, "/usr/local/bin/fdbcli")

  def exec(fdbcli_exec) do
    exec(fdbcli(), ExFdbmonitor.Cluster.file(), fdbcli_exec)
  end

  def exec(cluster_file, fdbcli_exec) do
    exec(fdbcli(), cluster_file, fdbcli_exec)
  end

  def exec(fdbcli, cluster_file, fdbcli_exec) when is_list(fdbcli_exec) do
    cmd = [
      fdbcli,
      "-C",
      cluster_file,
      "--exec",
      Enum.join(fdbcli_exec, " ")
    ]

    :exec.run(cmd, [:sync, :stdout, :stderr])
  end

  def exec(fdbcli, cluster_file, fdbcli_exec) do
    exec(fdbcli, cluster_file, String.split(fdbcli_exec, " "))
  end
end
