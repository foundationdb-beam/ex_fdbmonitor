# Changelog

## Unreleased

### Breaking Changes

- **Elixir >= 1.18 required** (was ~> 1.16).
- **Bootstrap config: `cluster: :autojoin` removed.** Peer detection is now
  automatic via `:erlang.nodes()`. All nodes use
  `cluster: [coordinator_addr: "..."]`; the first node (no peers) creates the
  cluster, others join automatically.
- **Bootstrap config: `fdbcli:` no longer needed for `configure new`.** The
  initial `configure new single <engine>` command is auto-generated for the
  first node. Explicit `fdbcli:` keys are still supported for additional
  commands.
- **`storage_engine` moves into `conf`.** Replaces the storage engine
  previously embedded in the `fdbcli:` command.
- **`redundancy_mode` moves into `conf`.** Replaces the former top-level
  `scale_up:` key. Each node declares the desired mode; the cluster configures
  itself when the minimum node count is reached.
- **`scale_up:` bootstrap key removed.** Use `redundancy_mode:` in `conf`
  instead.
- **FDB tenants removed from integration tests.**

### Before

```elixir
bootstrap: [
  cluster: if(x > 0, do: :autojoin, else: [coordinator_addr: "127.0.0.1"]),
  conf: [data_dir: "...", log_dir: "...", fdbservers: [[port: 5000]]],
  fdbcli: if(x == 0, do: ~w[configure new single ssd-2]),
  scale_up: if(x == n - 1, do: "double")
]
```

### After

```elixir
bootstrap: [
  cluster: [coordinator_addr: "127.0.0.1"],
  conf: [
    data_dir: "...", log_dir: "...",
    storage_engine: "ssd-2",
    fdbservers: [[port: 5000]],
    redundancy_mode: "double"
  ]
]
```

### Added

- `MgmtServer.set_redundancy_mode/1` — declarative redundancy configuration
  that triggers when enough nodes are registered.
- `MgmtServer` skips redundancy changes when current mode >= target.
- `MgmtServer.scale_up/2` now uses `coordinators auto` instead of manual
  coordinator selection.
- `MgmtServer.scale_down/2` prefers keeping existing coordinators on surviving
  nodes.
