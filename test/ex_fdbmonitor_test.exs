defmodule ExFdbmonitor.Integration.Case do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias ExFdbmonitor.Sandbox
  alias ExFdbmonitor.Sandbox.Double

  setup do
    sandbox = Double.checkout("ex-fdbmonitor-integration")

    on_exit(fn ->
      Double.checkin(sandbox, drop?: true)
    end)

    [nodes: Sandbox.nodes(sandbox), sandbox: sandbox]
  end
end

defmodule ExFdbmonitorTest do
  alias ExFdbmonitor.Sandbox
  use ExFdbmonitor.Integration.Case
  doctest ExFdbmonitor

  @tag timeout: :infinity
  test "making a cluster of three", context do
    [node1, node2, node3] = context[:nodes]

    [db1, db2, db3] =
      for node <- [node1, node2, node3] do
        cluster_file = Sandbox.cluster_file(node)
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
