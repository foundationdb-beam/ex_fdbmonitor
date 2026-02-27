require Logger

defmodule ExFdbmonitor do
  @moduledoc ("README.md"
              |> File.read!()
              |> String.split("<!-- MDOC !-->")
              |> Enum.fetch!(1)) <>
               """
               ## Usage

               See [examples/example_app/README.md](example-app.html) for a tutorial on
               using ExFdbmonitor in your application.
               """

  @doc """
  Opens a database connection.

  ## Arguments

  - `:input`: Ignored. It's here for compatibility with other libraries.

  ## Examples

  Use whenever you need to open the `t:erlfdb.database/0`:

  ```elixir
  db = ExFdbmonitor.open_db()
  "world" = :erlfdb.get(db, "hello")
  ```

  Use in conjuncation with `Ecto.Adapters.FoundationDB`:

  ```elixir
  config :my_app, MyApp.Repo,
    open_db: &ExFdbmonitor.open_db/1
  ```
  """
  def open_db(input \\ nil), do: ExFdbmonitor.Cluster.open_db(input)

  @doc """
  Gracefully remove the current node from the cluster.

  Executes `MgmtServer.scale_down/1` which, under the DGenServer lock:

  1. Downgrades the redundancy mode if the remaining nodes can no longer
     sustain it (e.g. triple → double when dropping below 5 nodes).
  2. Reassigns coordinators to surviving nodes.
  3. Excludes this node's FDB processes (blocks until data is fully moved).

  If the exclude succeeds the local worker is terminated
  so that `fdbmonitor` and its `fdbserver` processes are stopped.

  Returns `:ok` on success or `{:error, reason}` if the scale-down fails
  (in which case the worker is left running).

  ## Rejoining after leave

  Restart the `:ex_fdbmonitor` application.  The bootstrap flow will
  detect that data files already exist, skip the initial configure,
  and call `MgmtServer.scale_up/2` which includes the node back into
  FDB and reconfigures the redundancy mode if the cluster now has
  enough nodes.
  """
  def leave do
    node_name = node()
    Logger.notice("#{node_name} leaving")

    case ExFdbmonitor.MgmtServer.scale_down([node_name]) do
      {:ok, _} ->
        Logger.notice("#{node_name} excluded, stopping worker")
        Supervisor.terminate_child(ExFdbmonitor.Supervisor, ExFdbmonitor.Worker)

      {:error, _reason} = error ->
        error
    end
  end
end
