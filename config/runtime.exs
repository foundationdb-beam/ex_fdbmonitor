import Config

if config_env() == :prod do
  config :ex_fdbmonitor,
    fdbmonitor: System.get_env("FDBMONITOR_PATH") || "/usr/local/libexec/fdbmonitor",
    fdbcli: System.get_env("FDBCLI_PATH") || "/usr/local/bin/fdbcli",
    fdbserver: System.get_env("FDBSERVER_PATH") || "/usr/local/libexec/fdbserver",
    fdbdr: System.get_env("FDBDR_PATH") || "/usr/local/bin/fdbdr",
    backup_agent:
      System.get_env("BACKUP_AGENT_PATH") || "/usr/local/foundationdb/backup_agent/backup_agent",
    dr_agent: System.get_env("DR_AGENT_PATH") || "/usr/local/bin/dr_agent"

  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /var/lib/livesecret/data
      """

  config :ex_fdbmonitor,
    etc_dir: Path.join(database_path, "etc"),
    run_dir: Path.join(database_path, "run")

  node_idx = String.to_integer(System.get_env("NODE_IDX") || "0")
  node_count = String.to_integer(System.get_env("NODE_COUNT") || "1")
  interface = System.get_env("COORDINATOR_IF") || "lo"

  addr_fn = fn if ->
    {:ok, addrs} = :inet.getifaddrs()

    addrs
    |> then(&:proplists.get_value(~c"#{if}", &1))
    |> then(&:proplists.get_all_values(:addr, &1))
    |> Enum.filter(&(tuple_size(&1) == 4))
    |> hd()
    |> :inet.ntoa()
    |> to_string()
  end

  config :ex_fdbmonitor,
    bootstrap: [
      cluster:
        if(node_idx > 0,
          do: :autojoin,
          else: [
            coordinator_addr: addr_fn.(interface)
          ]
        ),
      conf: [
        data_dir: Path.join(database_path, "data"),
        log_dir: Path.join(database_path, "log"),
        memory: System.get_env("FDBSERVER_MEMORY") || nil,
        cache_memory: System.get_env("FDBSERVER_CACHE_MEMORY") || nil,
        fdbservers: [[port: 4500]]
      ],
      fdbcli:
        if(node_idx == 0,
          do: ~w[configure new single #{System.get_env("FDB_STORAGE_ENGINE") || "ssd-redwood-1"}]
        ),
      fdbcli: if(node_idx == 2, do: ~w[configure double]),
      fdbcli: if(node_idx == node_count - 1, do: ~w[coordinators auto])
    ]
end
