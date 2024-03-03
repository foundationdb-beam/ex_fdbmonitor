require Logger

defmodule ExFdbmonitor do
  @moduledoc """
  Documentation for `ExFdbmonitor`.
  """

  def autojoin!(nodes) do
    grouped_cluster_file_contents =
      nodes
      |> Enum.filter(fn node ->
        applications =
          :rpc.call(node, Application, :started_applications, [])

        not is_nil(List.keyfind(applications, :ex_fdbmonitor, 0))
      end)
      |> Enum.map(fn node ->
        {node, :rpc.call(node, ExFdbmonitor.Cluster, :read!, [])}
      end)
      |> Enum.group_by(fn {_, y} -> y end, fn {x, _} -> x end)
      |> Enum.to_list()

    # Crash if there is more than 1 cluster file active in cluster
    [{_content, [base_node | _]}] = grouped_cluster_file_contents

    Logger.notice("#{node()} joining via #{base_node}")
    join_cluster!(base_node)
  end

  def join_cluster!(base_node) do
    :ok = ExFdbmonitor.Cluster.copy_from!(base_node)

    applications = Application.started_applications()

    if not is_nil(List.keyfind(applications, :ex_fdbmonitor, 0)) do
      :ok = Application.stop(:ex_fdbmonitor)
      :ok = Application.start(:ex_fdbmonitor)
    end

    :ok
  end
end
