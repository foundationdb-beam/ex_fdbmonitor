defmodule ExFdbmonitor.Fdbcli do
  @moduledoc """
  This module provides functions for executing fdbcli commands.

  ## Options

  All `exec` variants accept an optional `opts` keyword list:

    * `:timeout` - maximum time in milliseconds to wait for fdbcli to complete.
      When set, the OS process is killed if it does not finish within the
      allotted time.

    * `:stderr` - whether to capture stderr (default `true`). Set to `false`
      when only stdout is needed, e.g. when parsing structured output like JSON.

  """
  defp fdbcli(), do: ExFdbmonitor.Binaries.fdbcli()

  @doc """
  Run a fdbcli command against the current node's cluster file.
  """
  def exec(fdbcli_exec) do
    exec(ExFdbmonitor.Cluster.file(), fdbcli_exec, [])
  end

  @doc """
  Run a fdbcli command against the given cluster file.
  """
  def exec(cluster_file, fdbcli_exec) do
    exec(cluster_file, fdbcli_exec, [])
  end

  @doc """
  Run a fdbcli command against the given cluster file with options.
  """
  def exec(cluster_file, fdbcli_exec, opts) when is_list(fdbcli_exec) do
    cmd =
      [fdbcli(), "-C", cluster_file, "--exec", Enum.join(fdbcli_exec, " ")]
      |> to_charlists()

    stderr_opts = if Keyword.get(opts, :stderr, true), do: [:stderr], else: []
    exec_opts = [:sync, :stdout] ++ stderr_opts

    case Keyword.get(opts, :timeout) do
      nil -> :exec.run(cmd, exec_opts)
      t -> :exec.run(cmd, exec_opts, t)
    end
  end

  def exec(cluster_file, fdbcli_exec, opts) do
    exec(cluster_file, String.split(fdbcli_exec, " "), opts)
  end

  defp to_charlists(cmd), do: Enum.map(cmd, &String.to_charlist/1)
end
