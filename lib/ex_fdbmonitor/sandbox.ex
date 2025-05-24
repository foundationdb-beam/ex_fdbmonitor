defmodule ExFdbmonitor.Sandbox do
  @moduledoc """
  Build a sandbox FoundationDB cluster.

  ## Examples

  ```elixir
  alias ExFdbmonitor.Sandbox

  Sandbox.start()
  cluster_file = Sandbox.cluster_file("dev", 0)
  sandbox = Sandbox.Single.checkout("dev", starting_port: 5050)
  IO.puts("Cluster file: \#{cluster_file}")
  _anything = IO.gets("Input anything to stop FDB: ")
  Sandbox.Single.checkin(sandbox)
  ```
  """

  defmodule Node do
    @moduledoc false
    defstruct [:idx, :node, :etc_dir, :data_dir, :run_dir, :log_dir]
  end

  alias ExFdbmonitor.Cluster
  alias ExFdbmonitor.Sandbox.Node

  def start() do
    {_, 0} = System.cmd("epmd", ["-daemon"])

    :ok = LocalCluster.start()
  end

  def stop() do
    LocalCluster.stop()
  end

  def nodes(context) do
    for %Node{node: node} <- context[:nodes], do: node
  end

  def cluster_file(name, idx) do
    etc_dir(name, idx)
    |> Path.expand()
    |> Cluster.file()
  end

  def cluster_file(node) when is_atom(node) do
    rpc!(%Node{node: node}, ExFdbmonitor.Cluster, :file, [])
  end

  def cluster_file(context) do
    [node | _] = context[:nodes]
    # Sandbox always uses nodes on the local machine, so this is guaranteed
    # to return a file on the same filesystem as the calling node
    rpc!(node, ExFdbmonitor.Cluster, :file, [])
  end

  def checkout(name, number, options \\ []) do
    environment = Keyword.get(options, :config, [])
    applications = Keyword.get(options, :applications, [:ex_fdbmonitor])

    {:ok, cluster} =
      LocalCluster.start_link(number, prefix: name, applications: [], environment: [])

    Process.unlink(cluster)

    {:ok, node_names} = LocalCluster.nodes(cluster)

    nodes = build_context(node_names, number, environment[:ex_fdbmonitor])

    load_and_put_env(nodes, environment ++ [ex_fdbmonitor: [nodes: node_names]])

    ensure_all_started(nodes, applications)

    [cluster: cluster, nodes: nodes]
  end

  def checkin(context, options \\ []) do
    nodes = Keyword.get(context, :nodes, [])
    drop? = Keyword.get(options, :drop?, false)
    cluster = Keyword.get(context, :cluster)

    :ok = LocalCluster.stop(cluster)

    if drop? do
      Enum.map(nodes, fn %Node{
                           etc_dir: etc_dir,
                           run_dir: run_dir,
                           data_dir: data_dir,
                           log_dir: log_dir
                         } ->
        for dir <- [etc_dir, run_dir, data_dir, log_dir] do
          if !is_nil(dir), do: File.rm_rf!(dir)
        end
      end)
    end

    :ok
  end

  def etc_dir(name, idx) do
    ".ex_fdbmonitor/#{name}.#{idx}/etc"
  end

  def run_dir(name, idx) do
    ".ex_fdbmonitor/#{name}.#{idx}/run"
  end

  def data_dir(name, idx) do
    ".ex_fdbmonitor/#{name}.#{idx}/data"
  end

  def log_dir(name, idx) do
    ".ex_fdbmonitor/#{name}.#{idx}/log"
  end

  def build_context(nodes, number, fdbmonitor_config) do
    [Enum.to_list(0..(number - 1)), nodes]
    |> Enum.zip()
    |> Enum.map(fn {idx, node} ->
      env = fdbmonitor_config.(idx, node)
      etc_dir = env[:etc_dir]
      run_dir = env[:run_dir]
      data_dir = env[:bootstrap][:conf][:data_dir]
      log_dir = env[:bootstrap][:conf][:log_dir]

      %Node{
        idx: idx,
        node: node,
        etc_dir: etc_dir,
        data_dir: data_dir,
        run_dir: run_dir,
        log_dir: log_dir
      }
    end)
  end

  defp load_and_put_env([], _environment) do
    :ok
  end

  defp load_and_put_env([node | nodes], environment) do
    load_and_put_env_on_node(environment, node)
    load_and_put_env(nodes, environment)
  end

  defp load_and_put_env_on_node([], _node) do
    :ok
  end

  defp load_and_put_env_on_node(
         [{app_name, env} | environment],
         node = %Node{idx: idx, node: node_name}
       )
       when is_function(env) do
    env_vars = env.(idx, node_name)
    load_and_put_env_on_node([{app_name, env_vars} | environment], node)
  end

  defp load_and_put_env_on_node([{app_name, env_vars} | environment], node) do
    rpc!(node, Application, :load, [app_name])

    for {k, v} <- env_vars do
      rpc!(node, Application, :put_env, [app_name, k, v])
    end

    load_and_put_env_on_node(environment, node)
  end

  defp ensure_all_started(nodes, applications) do
    for node <- nodes do
      for app_name <- applications do
        {:ok, _} = rpc!(node, Application, :ensure_all_started, [app_name])
      end
    end
  end

  defp rpc!(%Node{node: node}, module, function, args) do
    case :rpc.call(node, module, function, args) do
      error = {:badrpc, _reason} ->
        raise ":rpc.call(#{node}, #{module}, #{function}, ...) failed: #{inspect(error)}"

      result ->
        result
    end
  end
end
