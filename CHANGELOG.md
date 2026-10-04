# Changelog

## v0.2.3 (2026-10-04)

### Bug Fixes

- A node in a cluster bootstrapped before MgmtServer existed was never registered, so it failed to start with "not registered in MgmtServer". On a start that is not a fresh bootstrap, an unregistered node now registers itself by the `locality-machineid` in its own `foundationdb.conf`. A node whose machine id belongs to another node name, as after a rename, still fails as before, with a warning naming that node.

### Enhancements

- Added `ExFdbmonitor.MgmtServer.adopt_node/2`, which registers a node unless its machine id already belongs to another node, and `ExFdbmonitor.Conf.read_machine_id/0`.

### Dependencies

- Require erlexec ~> 2.5, erlfdb ~> 1.2, dgen ~> 0.4.2 and ex_doc ~> 0.40.

## v0.2.2 (2026-06-17)

### Dependencies

* Upgrade deps to latest

## v0.2.1 (2026-04-05)

### Bug Fixes

- Fixed `:crypto` and `:eex` missing from release by adding them to `extra_applications`.
- Fixed `runtime.exs` network interface lookup to fall back to `iface0` (e.g. `lo0` on macOS).
- Clearer error message when a node fails to start because it was registered under a different name during initial bootstrap.
- Fixed erlexec command arguments to pass charlists instead of binaries, matching the declared `cmd()` type spec. This resolved all dialyzer `no_return` warnings and removed the need for any dialyzer ignore entries.

### Enhancements

- Added `ExFdbmonitor.Binaries` module: centralises FDB binary path resolution with OS-aware defaults for Darwin and Linux, falling back to application config when set.
- `ExFdbmonitor.Fdbcli.exec/3` gains a `:timeout` option (milliseconds) and a `:stderr` option for controlling which streams are captured.
- Added GitHub Actions CI with lint and test jobs.

### Dependencies

- Updated erlfdb to 1.1
- Updated dgen to main branch (pending release of 0.3)

## v0.2.0 (2026-02-27)

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
