defmodule ExFdbmonitor.Integration.DoubleCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias ExFdbmonitor.Sandbox
  alias ExFdbmonitor.Sandbox.Double

  setup do
    sandbox = Double.checkout("double-integ", starting_port: 5200)

    on_exit(fn ->
      Double.checkin(sandbox, drop?: true)
    end)

    [nodes: Sandbox.nodes(sandbox), sandbox: sandbox]
  end
end

defmodule ExFdbmonitor.Integration.DoubleTest do
  alias ExFdbmonitor.Sandbox
  use ExFdbmonitor.Integration.DoubleCase

  @tag timeout: :infinity
  test "three-node double cluster with replication", context do
    [node1, node2, node3] = context[:nodes]

    # All nodes share identical cluster file content
    contents =
      for node <- [node1, node2, node3] do
        :rpc.call(node, ExFdbmonitor.Cluster, :read!, [])
      end

    assert length(Enum.uniq(contents)) == 1

    # All machine IDs are unique
    machine_ids =
      for node <- [node1, node2, node3] do
        {:ok, mid} = :rpc.call(node, ExFdbmonitor.MgmtServer, :get_machine_id, [node])
        assert is_binary(mid)
        mid
      end

    assert length(Enum.uniq(machine_ids)) == 3

    # Open databases from each node
    [db1, db2, db3] =
      for node <- [node1, node2, node3] do
        :erlfdb.open(Sandbox.cluster_file(node))
      end

    # Tenant created on node1 accessible from all
    tenant_name = "double-replication-test"
    :ok = :erlfdb_tenant_management.create_tenant(db1, tenant_name)
    [t1, t2, t3] = for db <- [db1, db2, db3], do: :erlfdb.open_tenant(db, tenant_name)

    # Write on node1, read from all 3
    :erlfdb.transactional(t1, fn tx ->
      :ok = :erlfdb.set(tx, "alpha", "one")
    end)

    for tenant <- [t1, t2, t3] do
      :erlfdb.transactional(tenant, fn tx ->
        assert "one" == :erlfdb.wait(:erlfdb.get(tx, "alpha"))
      end)
    end

    # Write on node2, read from node3
    :erlfdb.transactional(t2, fn tx ->
      :ok = :erlfdb.set(tx, "beta", "two")
    end)

    :erlfdb.transactional(t3, fn tx ->
      assert "two" == :erlfdb.wait(:erlfdb.get(tx, "beta"))
    end)

    # Write on node3, read from node1
    :erlfdb.transactional(t3, fn tx ->
      :ok = :erlfdb.set(tx, "gamma", "three")
    end)

    :erlfdb.transactional(t1, fn tx ->
      assert "three" == :erlfdb.wait(:erlfdb.get(tx, "gamma"))
    end)
  end
end
