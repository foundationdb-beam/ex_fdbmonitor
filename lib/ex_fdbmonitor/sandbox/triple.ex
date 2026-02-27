defmodule ExFdbmonitor.Sandbox.Triple do
  @moduledoc """
  This module provides functions for managing multi-node FoundationDB sandboxes in triple redundancy mode.
  """
  alias ExFdbmonitor.Sandbox

  @default_n 6

  def checkout(name, options \\ []) do
    n = Keyword.get(options, :nodes, @default_n)

    Sandbox.checkout(name, n, config: [ex_fdbmonitor: &config(&1, &2, name, options)])
  end

  def checkin(sandbox, options \\ []) do
    Sandbox.checkin(sandbox, options)
  end

  defp config(x, _node, name, options) do
    m = Keyword.get(options, :processes, 1)
    starting_port = Keyword.get(options, :starting_port, 5000)
    conf_assigns = Keyword.get(options, :conf_assigns, [])

    [
      bootstrap: [
        cluster: [],
        conf:
          Keyword.merge(
            [
              data_dir: Sandbox.data_dir(name, x),
              log_dir: Sandbox.log_dir(name, x),
              fdbservers: for(pidx <- 0..(m - 1), do: [port: starting_port + (x * m + pidx)]),
              storage_engine: "ssd-2",
              redundancy_mode: "triple"
            ],
            conf_assigns
          )
      ],
      etc_dir: Sandbox.etc_dir(name, x),
      run_dir: Sandbox.run_dir(name, x)
    ]
  end
end
