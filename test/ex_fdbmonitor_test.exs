defmodule ExFdbmonitor.Integration.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  setup do
    n = 3

    nodes =
      LocalCluster.start_nodes("ex-fdbmonitor-integration", n, applications: [], environment: [])

    nodes = List.zip([Enum.to_list(1..n), nodes])

    env_fn = fn x ->
      [
        bootstrap: [
          cluster:
            if(x > 1,
              do: :autojoin,
              else: [
                coordinator_addr: "127.0.0.1"
              ]
            ),
          conf: [
            data_dir: ".ex_fdbmonitor/#{x}/data",
            log_dir: ".ex_fdbmonitor/#{x}/log",
            fdbserver_ports: [5000 + x]
          ],
          fdbcli: if(x == 1, do: ~w[configure new single ssd tenant_mode=required_experimental]),
          fdbcli: if(x == 3, do: ~w[configure double]),
          fdbcli: if(x == 3, do: ~w[coordinators auto])
        ],
        etc_dir: ".ex_fdbmonitor/#{x}/etc",
        run_dir: ".ex_fdbmonitor/#{x}/run"
      ]
    end

    Enum.map(
      nodes,
      fn {idx, node} ->
        :ok = :rpc.call(node, Application, :load, [:ex_fdbmonitor])

        for {k, v} <- env_fn.(idx) do
          :ok = :rpc.call(node, Application, :put_env, [:ex_fdbmonitor, k, v])
        end

        {:ok, _} = :rpc.call(node, Application, :ensure_all_started, [:ex_fdbmonitor])
      end
    )

    on_exit(fn ->
      :ok = LocalCluster.stop()

      Enum.map(nodes, fn {idx, _node} ->
        env = env_fn.(idx)
        etc_dir = env[:etc_dir]
        run_dir = env[:run_dir]
        data_dir = env[:bootstrap][:conf][:data_dir]
        log_dir = env[:bootstrap][:conf][:log_dir]

        for dir <- [etc_dir, run_dir, data_dir, log_dir] do
          File.rm_rf!(dir)
        end
      end)
    end)

    [nodes: nodes]
  end
end

defmodule ExFdbmonitorTest do
  use ExFdbmonitor.Integration.Case
  doctest ExFdbmonitor

  @tag timeout: :infinity
  test "making a cluster of three", context do
    [{1, node1}, {2, node2}, {3, node3}] = context[:nodes]

    [db1, db2, db3] =
      for node <- [node1, node2, node3] do
        cluster_file = :rpc.call(node, ExFdbmonitor.Cluster, :file, [])
        :erlfdb.open(cluster_file)
      end

    tenant_name = "making a cluster of three"
    :ok = :erlfdb_tenant_management.create_tenant(db1, tenant_name)

    tenants =
      [tenant1, _tenant2, _tenant3] =
      for db <- [db1, db2, db3], do: :erlfdb.open_tenant(db, tenant_name)

    :erlfdb.transactional(tenant1, fn tx ->
      :ok = :erlfdb.set(tx, "hello", "world")
    end)

    for tenant <- tenants do
      :erlfdb.transactional(tenant, fn tx ->
        "world" = :erlfdb.wait(:erlfdb.get(tx, "hello"))
      end)
    end
  end
end
