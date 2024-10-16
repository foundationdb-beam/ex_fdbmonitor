defmodule ExFdbmonitor.Cluster do
  @fdb_cluster_eex "fdb.cluster.eex"
  @fdb_cluster "fdb.cluster"

  def file() do
    file(Application.fetch_env!(:ex_fdbmonitor, :etc_dir))
  end

  def open_db() do
    :erlfdb.open(file())
  end

  def read!() do
    File.read!(file())
  end

  def copy_from!(node) do
    content = :rpc.call(node, __MODULE__, :read!, [])
    File.write!(file(), content)
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
