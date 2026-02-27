# ExFdbmonitor

An Elixir application that manages [FoundationDB](https://www.foundationdb.org/)
clusters using the BEAM's distributed capabilities.

<!-- MDOC !-->

ExFdbmonitor starts and supervises `fdbmonitor` (the FoundationDB management
process), bootstraps new clusters, and handles scaling operations — all
coordinated across nodes via Erlang distribution.

## How it works

1. **First node** — detects that no FDB peers exist, creates the cluster file,
   writes a `foundationdb.conf`, and runs `configure new single <storage_engine>`.
2. **Subsequent nodes** — discover existing peers via `:erlang.nodes()`, copy
   the cluster file, and join the cluster.
3. **Redundancy** — once enough nodes are registered, `scale_up` configures
   coordinators and the declared redundancy mode (`"double"`, `"triple"`).
4. **Restarts** — on restart the bootstrap config is ignored (data files
   already exist). The node re-includes itself and re-evaluates redundancy
   automatically.

All mutating FDB operations are serialized through `ExFdbmonitor.MgmtServer`, a
[DGenServer](https://github.com/foundationdb-beam/dgen) backed by FDB itself.
This prevents concurrent `fdbcli` commands from interleaving across nodes.

## Requirements

- Elixir ~> 1.18
- FoundationDB client and server packages
  ([releases](https://github.com/apple/foundationdb/releases))

## Usage

See [examples/example_app/README.md](examples/example_app/README.md) for a tutorial on
using ExFdbmonitor in your application.

## Configuration

### FDB executable paths

If your FoundationDB installation is not in the default location, then you must set
the following environment variables. The paths shown here are the defaults.

```
config :ex_fdbmonitor,
       fdbmonitor: "/usr/local/libexec/fdbmonitor",
       fdbcli: "/usr/local/bin/fdbcli",
       fdbserver: "/usr/local/libexec/fdbserver",
       fdbdr: "/usr/local/bin/fdbdr",
       backup_agent: "/usr/local/foundationdb/backup_agent/backup_agent",
       dr_agent: "/usr/local/bin/dr_agent"
```

### Minimal (single-node dev)

```elixir
# config/dev.exs
import Config

config :ex_fdbmonitor,
  etc_dir: ".my_app/dev/fdb/etc",
  run_dir: ".my_app/dev/fdb/run"

config :ex_fdbmonitor,
  bootstrap: [
    cluster: [coordinator_addr: "127.0.0.1"],
    conf: [
      data_dir: ".my_app/dev/fdb/data",
      log_dir: ".my_app/dev/fdb/log",
      storage_engine: "ssd-2",
      fdbservers: [[port: 5000]]
    ]
  ]
```

### Multi-node production

```elixir
# config/runtime.exs
import Config

addr = fn interface ->
  {:ok, addrs} = :inet.getifaddrs()
  :proplists.get_value(to_charlist(interface), addrs)[:addr]
  |> :inet.ntoa()
  |> to_string()
end

config :ex_fdbmonitor,
  etc_dir: "/var/lib/my_app/fdb/etc",
  run_dir: "/var/lib/my_app/fdb/run"

config :ex_fdbmonitor,
  bootstrap: [
    cluster: [coordinator_addr: addr.("eth0")],
    conf: [
      data_dir: "/var/lib/my_app/fdb/data",
      log_dir: "/var/lib/my_app/fdb/log",
      storage_engine: "ssd-2",
      fdbservers: [[port: 4500], [port: 4501]],
      redundancy_mode: "double"
    ]
  ]
```

### Configuration reference

| Key | Required | Description |
|-----|----------|-------------|
| `:etc_dir` | yes | Directory for `fdb.cluster` and `foundationdb.conf` |
| `:run_dir` | yes | Directory for `fdbmonitor` pid file |
| `:bootstrap` | no | Bootstrap config (ignored after first successful start) |

**Bootstrap keys:**

| Key | Description |
|-----|-------------|
| `cluster: [coordinator_addr:]` | IP address for the initial coordinator |
| `conf: [data_dir:]` | FDB data directory |
| `conf: [log_dir:]` | FDB log directory |
| `conf: [storage_engine:]` | Storage engine (default `"ssd-2"`) |
| `conf: [fdbservers:]` | List of `[port: N]` keyword lists, one per `fdbserver` process |
| `conf: [redundancy_mode:]` | `"single"`, `"double"`, or `"triple"` (default: `nil` / single) |
| `fdbcli:` | Extra `fdbcli` args to run at bootstrap (optional, repeatable) |

## Bootstrap flow

On application start, ExFdbmonitor runs two phases:

**Phase 1** (before any processes start):
- If the conf file and data dir are empty (first boot), write config files.
  If FDB peers exist on `:erlang.nodes()`, copy their cluster file.
  Otherwise, create a new cluster file and generate `configure new single <engine>`.
- If files already exist (restart), skip — use existing cluster file.

**Phase 2** (after `fdbmonitor` / `fdbserver` are running):
- Start `ExFdbmonitor.MgmtServer` (connects to FDB for distributed coordination).
- Register this node's `machine_id`.
- Call `scale_up(redundancy_mode, [node()])` — includes the node back
  into FDB and configures redundancy when enough nodes are present.

## Public API

### `ExFdbmonitor.leave/0`

Gracefully remove the current node from the cluster. Downgrades redundancy
if needed, reassigns coordinators, excludes the node (blocks until data is
moved), and stops the local `fdbmonitor`. To rejoin, restart the
`:ex_fdbmonitor` application.

### Redundancy modes

| Mode | Min nodes | Min coordinators |
|------|-----------|------------------|
| `"single"` | 1 | 1 |
| `"double"` | 3 | 3 |
| `"triple"` | 5 | 5 |

`scale_up` stores the declared mode as a ceiling. `scale_down`
auto-determines the highest mode the surviving nodes can support, capped
at that ceiling. This prevents a scale-down/scale-up cycle from
accidentally exceeding the operator's intent.

## Scaling example

When a node is gracefully shutting down,

```elixir
# On the departing node:
ExFdbmonitor.leave()
```

When a node is returning from previously having been gracefully shutdown,

```elixir
# Later, restart the :ex_fdbmonitor application to rejoin:
Application.stop(:ex_fdbmonitor)
Application.ensure_all_started(:ex_fdbmonitor)
```

## Testing

ExFdbmonitor provides sandbox modules for integration testing:

```elixir
# Single-node sandbox
sandbox = ExFdbmonitor.Sandbox.Single.checkout("my-test", starting_port: 5000)
# ... run tests ...
ExFdbmonitor.Sandbox.Single.checkin(sandbox, drop?: true)

# 3-node double-redundancy sandbox
sandbox = ExFdbmonitor.Sandbox.Double.checkout("my-test", starting_port: 5500)
# ... run tests ...
ExFdbmonitor.Sandbox.Double.checkin(sandbox, drop?: true)
```

Sandboxes start isolated `local_cluster` nodes with their own FDB
processes. Pass `drop?: true` to delete all data on checkin.
