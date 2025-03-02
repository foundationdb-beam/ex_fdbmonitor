defmodule ExFdbmonitor.Sandbox.Double do
  @moduledoc """
  This module provides functions for managing multi-node FoundationDB sandboxes in double redundancy mode.
  """
  alias ExFdbmonitor.Sandbox

  @default_n 3

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
        cluster:
          if(x > 0,
            do: :autojoin,
            else: [
              coordinator_addr: "127.0.0.1"
            ]
          ),
        conf:
          Keyword.merge(
            [
              data_dir: Sandbox.data_dir(name, x),
              log_dir: Sandbox.log_dir(name, x),
              fdbservers: for(pidx <- 0..(m - 1), do: [port: starting_port + (x * m + pidx)])
            ],
            conf_assigns
          ),
        fdbcli:
          if(x == 0, do: ~w[configure new single ssd-redwood-1 tenant_mode=optional_experimental]),
        fdbcli: if(x == 2, do: ~w[configure double]),
        fdbcli: if(x == 2, do: ~w[coordinators auto])
      ],
      etc_dir: Sandbox.etc_dir(name, x),
      run_dir: Sandbox.run_dir(name, x)
    ]
  end
end
