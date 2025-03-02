require Logger

defmodule ExFdbmonitor.Fdbdr do
  @moduledoc """
  This module provides functions for executing fdbdr commands.
  """
  defp fdbdr(), do: Application.get_env(:ex_fdbmonitor, :fdbdr, "/usr/local/bin/fdbdr")

  def exec(command, source, destination) do
    exec(fdbdr(), ["#{command}", "--source", source, "--destination", destination])
  end

  defp exec(fdbdr, args) when is_list(args) do
    cmd = [fdbdr] ++ args

    Logger.notice("fdbdr exec #{inspect(args)}")

    :exec.run(cmd, [:sync, :stdout, :stderr])
  end
end
