defmodule ExFdbmonitor.Integration.TripleCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias ExFdbmonitor.Sandbox
  alias ExFdbmonitor.Sandbox.Triple

  setup do
    sandbox = Triple.checkout("triple-integ", starting_port: 5300)

    on_exit(fn ->
      Triple.checkin(sandbox, drop?: true)
    end)

    [nodes: Sandbox.nodes(sandbox), sandbox: sandbox]
  end
end

defmodule ExFdbmonitor.Integration.TripleTest do
  alias ExFdbmonitor.Sandbox
  use ExFdbmonitor.Integration.TripleCase

  @tag timeout: :infinity
  test "six-node triple cluster with replication", context do
    nodes = context[:nodes]
    assert length(nodes) == 6

    # All 6 nodes share identical cluster file content
    contents =
      for node <- nodes do
        :rpc.call(node, ExFdbmonitor.Cluster, :read!, [])
      end

    assert length(Enum.uniq(contents)) == 1

    # All 6 machine IDs are unique
    machine_ids =
      for node <- nodes do
        {:ok, mid} = :rpc.call(node, ExFdbmonitor.MgmtServer, :get_machine_id, [node])
        assert is_binary(mid)
        mid
      end

    assert length(Enum.uniq(machine_ids)) == 6

    # Open all databases
    dbs = for node <- nodes, do: :erlfdb.open(Sandbox.cluster_file(node))

    # Create tenant from first node
    tenant_name = "triple-test"
    :ok = :erlfdb_tenant_management.create_tenant(hd(dbs), tenant_name)
    tenants = for db <- dbs, do: :erlfdb.open_tenant(db, tenant_name)

    # Write on first node, read from all 6
    :erlfdb.transactional(hd(tenants), fn tx ->
      :ok = :erlfdb.set(tx, "triple_key", "triple_value")
    end)

    for tenant <- tenants do
      :erlfdb.transactional(tenant, fn tx ->
        assert "triple_value" == :erlfdb.wait(:erlfdb.get(tx, "triple_key"))
      end)
    end

    # Write from last node, read from first
    :erlfdb.transactional(List.last(tenants), fn tx ->
      :ok = :erlfdb.set(tx, "reverse_key", "reverse_value")
    end)

    :erlfdb.transactional(hd(tenants), fn tx ->
      assert "reverse_value" == :erlfdb.wait(:erlfdb.get(tx, "reverse_key"))
    end)
  end
end
