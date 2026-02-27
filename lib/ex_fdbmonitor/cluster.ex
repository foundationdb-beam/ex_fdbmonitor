require Logger

defmodule ExFdbmonitor.Cluster do
  @moduledoc false

  @fdb_cluster_eex "fdb.cluster.eex"
  @fdb_cluster "fdb.cluster"

  def file() do
    file(Application.fetch_env!(:ex_fdbmonitor, :etc_dir))
  end

  def open_db(_repo) do
    :erlfdb.open(file())
  end

  def read!() do
    File.read!(file())
  end

  def copy_from!(node) do
    content = :rpc.call(node, __MODULE__, :read!, [])
    File.write!(file(), content)
  end

  @doc """
  Join an existing cluster by copying the cluster file from a peer.

  Reads the cluster file from each node in `nodes` that is running
  `:ex_fdbmonitor`, groups them by content, and crashes if more than
  one distinct cluster file is found.  Copies the file from the first
  reachable peer.
  """
  def join!(nodes) do
    grouped =
      nodes
      |> Enum.filter(fn node ->
        case :rpc.call(node, Application, :started_applications, []) do
          {:badrpc, _} -> false
          apps -> not is_nil(List.keyfind(apps, :ex_fdbmonitor, 0))
        end
      end)
      |> Enum.flat_map(fn node ->
        case :rpc.call(node, __MODULE__, :read!, []) do
          {:badrpc, _} -> []
          content -> [{node, content}]
        end
      end)
      |> Enum.group_by(fn {_, y} -> y end, fn {x, _} -> x end)
      |> Enum.to_list()

    # Crash if there is more than 1 cluster file active in cluster
    [{_content, [base_node | _]}] = grouped

    Logger.notice("#{node()} joining via #{base_node}")
    copy_from!(base_node)
  end

  def file(etc_dir) do
    Path.expand(Path.join([etc_dir, @fdb_cluster]))
  end

  def write!(etc_dir, assigns) do
    file = file(etc_dir)

    File.write!(file, ExFdbmonitor.Cluster.render(assigns))

    file
  end

  def render(assigns) do
    eex_file = Path.join([:code.priv_dir(:ex_fdbmonitor), @fdb_cluster_eex])

    EEx.eval_file(eex_file,
      assigns:
        [
          cluster_name: Base.encode16(:crypto.strong_rand_bytes(4)),
          cluster_id: Base.encode16(:crypto.strong_rand_bytes(4))
        ] ++ assigns
    )
  end
end
