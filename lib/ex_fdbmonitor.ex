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

  @doc false
  def autojoin!(nodes) do
    grouped_cluster_file_contents =
      nodes
      |> Enum.filter(fn node ->
        case :rpc.call(node, Application, :started_applications, []) do
          {:badrpc, _} -> false
          applications -> not is_nil(List.keyfind(applications, :ex_fdbmonitor, 0))
        end
      end)
      |> Enum.flat_map(fn node ->
        case :rpc.call(node, ExFdbmonitor.Cluster, :read!, []) do
          {:badrpc, _} -> []
          content -> [{node, content}]
        end
      end)
      |> Enum.group_by(fn {_, y} -> y end, fn {x, _} -> x end)
      |> Enum.to_list()

    # Crash if there is more than 1 cluster file active in cluster
    [{_content, [base_node | _]}] = grouped_cluster_file_contents

    Logger.notice("#{node()} joining via #{base_node}")
    join_cluster!(base_node)
  end

  def leave() do
    node_name = node()
    Logger.notice("#{node_name} leaving")

    case ExFdbmonitor.MgmtServer.exclude(node_name) do
      {:ok, _} ->
        Logger.notice("#{node_name} excluded, stopping worker")
        Supervisor.terminate_child(ExFdbmonitor.NodeSupervisor, ExFdbmonitor.Worker)

      {:error, _reason} = error ->
        error
    end
  end

  def rejoin() do
    node_name = node()
    Logger.notice("#{node_name} rejoining")

    {:ok, _} = Supervisor.restart_child(ExFdbmonitor.NodeSupervisor, ExFdbmonitor.Worker)
    Logger.notice("#{node_name} worker restarted")

    case ExFdbmonitor.MgmtServer.include(node_name) do
      {:ok, _} ->
        Logger.notice("#{node_name} included")
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  def join_cluster!(base_node) do
    :ok = ExFdbmonitor.Cluster.copy_from!(base_node)

    :ok = Supervisor.terminate_child(ExFdbmonitor.NodeSupervisor, ExFdbmonitor.MgmtServer)
    {:ok, _} = Supervisor.restart_child(ExFdbmonitor.NodeSupervisor, ExFdbmonitor.MgmtServer)

    :ok
  end
end
