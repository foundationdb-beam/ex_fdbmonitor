defmodule ExFdbmonitor.Sandbox.Double do
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
    n = Keyword.get(options, :nodes, @default_n)
    m = Keyword.get(options, :processes, 1)
    starting_port = Keyword.get(options, :starting_port, 5000)
    root_dir = Keyword.get(options, :root_dir, ".ex_fdbmonitor")

    [
      bootstrap: [
        cluster:
          if(x > 0,
            do: :autojoin,
            else: [
              coordinator_addr: "127.0.0.1"
            ]
          ),
        conf: [
          data_dir: "#{root_dir}/#{name}.#{x}/data",
          log_dir: "#{root_dir}/#{name}.#{x}/log",
          fdbserver_ports: for(pidx <- 0..m, do: starting_port + (x * n + pidx))
        ],
        fdbcli: if(x == 0, do: ~w[configure new single ssd tenant_mode=required_experimental]),
        fdbcli: if(x == 2, do: ~w[configure double]),
        fdbcli: if(x == 2, do: ~w[coordinators auto])
      ],
      etc_dir: ".ex_fdbmonitor/#{name}.#{x}/etc",
      run_dir: ".ex_fdbmonitor/#{name}.#{x}/run"
    ]
  end
end
