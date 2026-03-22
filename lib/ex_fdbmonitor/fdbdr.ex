require Logger

defmodule ExFdbmonitor.Fdbdr do
  @moduledoc """
  This module provides functions for executing fdbdr commands.
  """
  defp fdbdr(), do: ExFdbmonitor.Binaries.fdbdr()

  def exec(command, source, destination) do
    exec(fdbdr(), ["#{command}", "--source", source, "--destination", destination])
  end

  defp exec(fdbdr, args) when is_list(args) do
    cmd = Enum.map([fdbdr | args], &String.to_charlist/1)

    Logger.notice("fdbdr exec #{inspect(args)}")

    :exec.run(cmd, [:sync, :stdout, :stderr])
  end
end
