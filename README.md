# ExFdbmonitor

<!-- MDOC !-->

ExFdbmonitor is an Elixir application that manages the starting and stopping of
`fdbmonitor`, which is the management process for FoundationDB.

The goal of ExFdbmonitor is to allow a FoundationDB cluster to bootstrap itself
using the distributed capabilities of the Erlang VM.

With a correctly crafted set of application environment variables, a cluster
can be brought up from zero as long as each node is started individually.

Once the cluster is established, node restarts are equivalent to restarts of
`fdbmonitor` itself.

## Configuration of `:ex_fdbmonitor`

### FDB executable paths

If your FoundationDB installation is not in the default location, then you must set
the following environment variables. The paths shown here are the defaults.

```
config :ex_fdbmonitor,
       fdbcli: "/usr/local/bin/fdbcli",
       fdbserver: "/usr/local/libexec/fdbserver",
       fdbdr: "/usr/local/bin/fdbdr",
       backup_agent: "/usr/local/foundationdb/backup_agent/backup_agent",
       dr_agent: "/usr/local/bin/dr_agent"
```

### FDB cluster configuration

The env vars `:etc_dir` and `:run_dir` are used on every boot.

```elixir
database_path = "/var/lib/myapp/data/fdb"

config :ex_fdbmonitor,
  etc_dir: Path.join(database_path, "etc"),
  run_dir: Path.join(database_path, "run")
```

The `:bootstrap` env var is used only on first boot of each node in the cluster.
Once a cluster is established, it is ignored on all subsequent boots. A simple
example is shown here.

```elixir
config :ex_fdbmonitor,
  bootstrap: [
    cluster: [
      coordinator_addr: "127.0.0.1"
    ],
    conf: [
      data_dir: Path.join(database_path, "data"),
      log_dir: Path.join(database_path, "log"),
      fdbservers: [
        [port: 5000]
      ]
    ],
    fdbcli: ~w[configure new single ssd-redwood-1]
  ]
```

<!-- MDOC !-->

## Usage

See [examples/example_app/README.md](examples/example_app/README.md) for a tutorial on
using ExFdbmonitor in your application.
