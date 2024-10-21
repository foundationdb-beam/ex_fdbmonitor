# ExampleApp

This is an example application that demonstrates how to use `ex_fdbmonitor` in both
development and production along with `ecto_foundationdb`. Together, these two
dependencies can be a basis for how your application state is managed across different
environments.

This README contains the list of steps taken to construct this example, so
that the reader may follow along with their own application.

## Guide

### Install system dependencies

From [FoundationDB Releases](https://github.com/apple/foundationdb/releases), choose the latest
stable release, and install the `foundationdb-clients` and `foundationdb-server` packages for your
system.

At the time of writing, a MacOS system should use [FoundationDB-7.3.42_arm64.pkg](https://github.com/apple/foundationdb/releases/download/7.3.42/FoundationDB-7.3.42_arm64.pkg)
to install both `foundationdb-clients` and `foundationdb-server`.

### Create the application with mix

```bash
mix new example_app --sup
cd example_app
```

```bash
# .gitignore
/.example_app/
/.erlfdb/
```

### Set up application config

This section describes a conventional way to manage application config in differing
mix environments. For now, we'll leave the config files empty, and we'll fill them in
later.

```bash
mkdir config
touch config/dev.exs config/test.exs config/prod.exs
```

```elixir
# config/config.exs
import Config

import_config "#{config_env()}.exs"
```

### Add `:ecto_foundationdb` and `:ex_fdbmonitor` deps

**TODO: Replace with hex package**

```elixir
  # mix.exs
  defp deps do
  [
    {:ecto_foundationdb, "~> 0.1"},
    {:ex_fdbmonitor, git: "https://github.com/foundationdb-beam/ex_fdbmonitor.git", branch: "main", only: :dev}
  ]
  end
```

```bash
mix deps.get
mix
```

You'll see a warning, which we will address in the next step.

```
10:14:17.299 [warning] ExFdbmonitor starting without running fdbmonitor. At minimum, you
should define `:etc_dir` and `:run_dir`, but you should also consider
adding a `:bootstrap` config.
```

### For `MIX_ENV=dev`

The dev.exs configuration shown here creates a working directory for FoundationDB
that is expected to be semi-permanent. That is, this FoundationDB cluster (of 1 node)
can be kept long term during development of your application.

You can modify the directories and port(s) according to your needs.

Note: Please don't consider this a "Sandbox". Sandboxes should be reserved for
clusters that are ephemeral and safe to delete at any time.

#### Configure ex_fdbmonitor

When your app is running with this config, it will start a single fdbserver process
and it will listen on port 5000. It uses the ssd-redwood-1 storage engine and
enables tenants, which EctoFDB requires.

```elixir
# config/dev.exs
import Config

config :example_app, ExampleApp.Repo,
  open_db: &ExFdbmonitor.Cluster.open_db/1

config :ex_fdbmonitor,
  etc_dir: ".example_app/dev/fdb/etc",
  run_dir: ".example_app/dev/fdb/run"

config :ex_fdbmonitor,
  bootstrap: [
    cluster: [
      coordinator_addr: "127.0.0.1"
    ],
    conf: [
      data_dir: ".example_app/dev/fdb/data",
      log_dir: ".example_app/dev/fdb/log",
      fdbservers: [
        [port: 5000]
      ]
    ],
    fdbcli: ~w[configure new single ssd-redwood-1]
  ]
```

#### Verify dev FDB

To verify this config, you can run

```bash
iex -S mix
```

and then

```elixir
iex(1)> ExFdbmonitor.Fdbcli.exec("status minimal")
{:ok, [stdout: ["The database is available.\n"]]}
```

which is equivalent to

```bash
fdbcli -C .example_app/dev/fdb/etc/fdb.cluster --exec "status minimal"
```

### Creating `ExampleApp.Repo`

Before setting up `mix test`, let's make sure our app can interact with a database
via `Ecto`.

```elixir
# lib/example_app/repo.ex
defmodule ExampleApp.Repo do
  use Ecto.Repo, otp_app: :example_app, adapter: Ecto.Adapters.FoundationDB

  use EctoFoundationDB.Migrator

  def migrations(), do: []
end
```

```elixir
# lib/example_app/application.ex
defmodule ExampleApp.Application do
  # ...
  def start(_type, _args) do
    children = [
      ExampleApp.Repo
    ]

    # ...
  end
end
```

### For `MIX_ENV=test`

In the configuration of `test.exs` we're actually not using `ex_fdbmonitor`, and instead
using `EctoFoundationDB.Sandbox`. Instead of creating a FoundationDB cluster, this sandbox
manages a single `fdbserver` process. The port is chosen automatically, and it is not
necessary for your application to inspect this port. The sandbox will create the directory
`.erlfdb`. This is not configurable.

#### Configure test.exs

This is an important step that will ensure `mix test` does not connect to a FoundationDB
database that is running on your system in the default location.

```elixir
# test.exs
import Config

config :example_app, ExampleApp.Repo, open_db: &EctoFoundationDB.Sandbox.open_db/1
```

#### Set up supporting files

We define an ExUnit Case to be used by any of your tests that require a database
connection. It's called `TenantCase` because it sets up a randomly generated
FoundationDB Tenant so that each Case is fully isolated in the database, which
ensures that your tests can execute concurrently.

You are encouraged to adapt this Case based on the needs of your application, but
avoid using a common `tenant_id`, as this will break the isolation.

Also note that `EctoFoundationDB.Sandbox` will delete all existing data in the tenant
at `checkout` time, and will delete the tenant entirely on `checkin`.

```bash
mkdir test/support
touch test/support/tenant_case.ex
```

```elixir
# test/support/tenant_case.ex
defmodule ExampleApp.TenantCase do
  use ExUnit.CaseTemplate
  alias Ecto.UUID
  alias EctoFoundationDB.Sandbox
  alias ExampleApp.Repo

  setup do
    tenant_id = UUID.autogenerate()
    tenant = Sandbox.checkout(Repo, tenant_id, [])

    on_exit(fn ->
      Sandbox.checkin(Repo, tenant_id)
    end)

    {:ok, [tenant_id: tenant_id, tenant: tenant]}
  end
end
```

The following edits to mix.exs will ensure your new Case is compiled by mix.

```elixir
# mix.exs
def project do
  [
    app: :example_app,
    # ...
    elixirc_paths: elixirc_paths(Mix.env()),
    # ...
  ]
end
# ...
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

Finally, we can write our test, which simply runs a trivial transaction. Of course,
this is where you'll put test logic that is relevant to your application.

```elixir
# test/example_app_test.exs
defmodule ExampleAppTest do
  use ExampleApp.TenantCase
  test "greets the world", context do
    tenant = context[:tenant]
    assert :ok = ExampleApp.Repo.transaction(fn -> :ok end, prefix: tenant)
  end
end
```

You should now be able to run `mix test` successfully. You can safely delete the `.erlfdb` directory
at any time throughout development.

### For `MIX_ENV=prod`

In production, you have a choice. It's likely that you'll want to host FoundationDB on compute instances that
are separated from your application (Conventional), but there are other configurations that might be
interesting to you (Radical).

#### Conventional: connect to remote database

Simply construct prod.exs like so:

```elixir
# config/prod.exs
import Config

config :example_app, ExampleApp.Repo,
  cluster_file: "/etc/foundationdb/fdb.cluster"
```

The `:cluster_file` option should identify a file on the filesystem. Your application should have both read
and write access to this file. The contents of this file are generated by the FoundationDB server and should not
be changed by hand.

You'll also want to ensure that your compute instance has sufficient network access to the FDB coordinators
that are listed in the cluster file.

#### Radical: application manages its own database cluster

Alternatively, your app's production config can bootstrap its own multi-node FoundationDB cluster. `ex_fdbmontior`
makes it easy to use the BEAM's clustering capabilities for node discovery. There are a couple reasons why you
might consider this approach.

1. Your applicatiion needs multi-node ACID transactions, and you don't want the complexity or cost
   associated with hosting a separate database.
2. You run a deployment of your application that acts as the database and a deployment that acts as the
   stateless application. Similar to the approach used by FLAME, you could create a `MIX_ENV=db`
   variant of your app that runs `ex_fdbmonitor` and bootstraps the database, whereas `MIX_ENV=prod`
   simply connects to it.
3. You create an entirely separate Elixir app that is strictly concerned with running `ex_fdbmonitor`.
   Once such an application is running, your main application can use the Conventional approach.

In any of these cases, your runtime.config could resemble something like this:

```elixir
# config/runtime.exs
import Config

config :ex_fdbmonitor,
  etc_dir: "/var/lib/example_app/data/fdb/etc",
  run_dir: "/var/lib/example_app/data/fdb/run"

node_idx = Integer.parse(System.fetch_env!("EXAMPLE_APP_NODE_IDX"))

addr_fn = fn if ->
  {:ok, addrs} = :inet.getifaddrs()
  :proplists.get_value(to_charlist(if), addrs)[:addr]
  |> :inet.ntoa()
  |> to_string()
end

config :ex_fdbmonitor,
  bootstrap: [
    cluster:
    if(node_idx > 0,
      do: :autojoin,
      else: [
        coordinator_addr: addr_fn.("en0")
      ]
    ),
    conf: [
      data_dir: "/var/lib/example_app/data/fdb/data",
      log_dir: "/var/lib/example_app/data/fdb/log",
      fdbservers: [port: 4500, port: 4501]
    ],
    fdbcli: if(node_idx == 0, do: ~w[configure new single ssd-redwood-1]),
    fdbcli: if(node_idx == 2, do: ~w[configure double]),
    fdbcli: if(node_idx == 2, do: ~w[coordinators auto])
  ]
```

Keep in mind that `:erlang.nodes()` is used to detect nodes that any given node can join to in
order to form the cluster on first boot. So your nodes must be able to reach each other.

On first bring-up, nodes should be started individually and serially.

Once a given node has been started, the `bootstrap` config, will be ignored on all subsequent restarts.

The example config above uses a per-node index value to control the sequence of commands in the bootstrap.
Feel free to use some other piece of data convenient to your deployment procedure.

### Schemas and Migrations

For completeness, we'll give our ExampleApp a Schema to write data to and give it an index via a Migration.
We suggest the reader consult the EctoFoundationDB documentation for details regarding Schemas, Indexes,
and Migrations. We'll provide a minimal set-up here to get you started.

#### Schema

Defines a struct your app stores in the database.

```elixir
# lib/example_app/temperature_event.ex
defmodule ExampleApp.TemperatureEvent do
  use Ecto.Schema
  @schema_context usetenant: true
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "temperature_events" do
    field(:recorded_at, :naive_datetime_usec)
    field(:kelvin, :float)
    field(:site, :string)
    timestamps()
  end
end
```

#### Indexes

Defines the fields that can be used to efficiently access your data.

```elixir
# lib/example_app/migrations/temperature_event_indexes.ex
defmodule ExampleApp.Migrations.TemperatureEventIndexes do
  use EctoFoundationDB.Migration
  alias ExampleApp.TemperatureEvent

  def change() do
    [
      create(index(TemperatureEvent, [:site])),
      create(index(TemperatureEvent, [:recorded_at]))
    ]
  end
end
```

#### Migration

Defines the order in which the indexes are created and the corresponding monotonically increasing version numbers.

```elixir
# lib/example_app/repo.ex
defmodule ExampleApp.Repo do
  # ...

  def migrations() do
    [{0, ExampleApp.Migrations.TemperatureEventIndexes}]
  end
end
```

#### Test

Finally, we can write some data!

```elixir
# test/example_app_test.exs
defmodule ExampleAppTest do
  use ExampleApp.TenantCase
  alias ExampleApp.TemperatureEvent
  alias ExampleApp.Repo

  test "greets the world", context do
    tenant = context[:tenant]

    event =
      Repo.insert!(
        %TemperatureEvent{kelvin: 13.37, site: "L2", recorded_at: NaiveDateTime.utc_now()},
        prefix: tenant
      )

    assert %TemperatureEvent{site: "L2"} = event

    assert ^event = Repo.get_by!(TemperatureEvent, [site: "L2"], prefix: tenant)
  end
end
```
