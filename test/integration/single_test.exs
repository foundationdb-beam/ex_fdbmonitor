defmodule ExFdbmonitor.Integration.SingleCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias ExFdbmonitor.Sandbox
  alias ExFdbmonitor.Sandbox.Single

  setup do
    sandbox = Single.checkout("single-integ", starting_port: 5100)

    on_exit(fn ->
      Single.checkin(sandbox, drop?: true)
    end)

    [nodes: Sandbox.nodes(sandbox), sandbox: sandbox]
  end
end

defmodule ExFdbmonitor.Integration.SingleTest do
  alias ExFdbmonitor.Sandbox
  use ExFdbmonitor.Integration.SingleCase

  @tag timeout: :infinity
  test "single node cluster", context do
    [node1] = context[:nodes]

    # Cluster file is readable
    cluster_content = :rpc.call(node1, ExFdbmonitor.Cluster, :read!, [])
    assert is_binary(cluster_content)

    # MgmtServer is running
    mgmt_pid = :rpc.call(node1, GenServer, :whereis, [ExFdbmonitor.MgmtServer])
    assert is_pid(mgmt_pid)

    # Machine ID registered
    {:ok, machine_id} = :rpc.call(node1, ExFdbmonitor.MgmtServer, :get_machine_id, [node1])
    assert is_binary(machine_id)

    # Worker is alive under supervisor
    children = :rpc.call(node1, Supervisor, :which_children, [ExFdbmonitor.Supervisor])
    {ExFdbmonitor.Worker, worker_pid, :worker, _} =
      Enum.find(children, fn {id, _, _, _} -> id == ExFdbmonitor.Worker end)
    assert is_pid(worker_pid)

    # Tenant CRUD
    cluster_file = Sandbox.cluster_file(node1)
    db = :erlfdb.open(cluster_file)

    tenant_name = "single-test"
    :ok = :erlfdb_tenant_management.create_tenant(db, tenant_name)
    tenant = :erlfdb.open_tenant(db, tenant_name)

    :erlfdb.transactional(tenant, fn tx ->
      :ok = :erlfdb.set(tx, "key1", "value1")
      :ok = :erlfdb.set(tx, "key2", "value2")
    end)

    :erlfdb.transactional(tenant, fn tx ->
      assert "value1" == :erlfdb.wait(:erlfdb.get(tx, "key1"))
      assert "value2" == :erlfdb.wait(:erlfdb.get(tx, "key2"))
    end)
  end
end
