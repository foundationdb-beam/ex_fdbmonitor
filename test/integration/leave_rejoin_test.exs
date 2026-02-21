defmodule ExFdbmonitor.Integration.LeaveRejoinCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias ExFdbmonitor.Sandbox
  alias ExFdbmonitor.Sandbox.Double

  setup do
    sandbox = Double.checkout("lr-integ", starting_port: 5500)

    on_exit(fn ->
      Double.checkin(sandbox, drop?: true)
    end)

    [nodes: Sandbox.nodes(sandbox), sandbox: sandbox]
  end
end

defmodule ExFdbmonitor.Integration.LeaveRejoinTest do
  alias ExFdbmonitor.Sandbox
  use ExFdbmonitor.Integration.LeaveRejoinCase

  @tag timeout: :infinity
  test "leave stops worker and data survives, rejoin restores access", context do
    [node1, node2, node3] = context[:nodes]

    # Open databases and create tenant
    dbs = for node <- [node1, node2, node3], do: :erlfdb.open(Sandbox.cluster_file(node))
    tenant_name = "lr-test"
    :ok = :erlfdb_tenant_management.create_tenant(hd(dbs), tenant_name)
    tenants = for db <- dbs, do: :erlfdb.open_tenant(db, tenant_name)
    [t1, t2, t3] = tenants

    # ── Phase 1: Baseline ──
    # Write data, confirm readable from all 3 nodes
    :erlfdb.transactional(t1, fn tx ->
      :ok = :erlfdb.set(tx, "baseline", "data")
    end)

    for tenant <- tenants do
      :erlfdb.transactional(tenant, fn tx ->
        assert "data" == :erlfdb.wait(:erlfdb.get(tx, "baseline"))
      end)
    end

    # Verify node3 Worker is running
    children = :rpc.call(node3, Supervisor, :which_children, [ExFdbmonitor.Supervisor])
    {ExFdbmonitor.Worker, worker_pid_before, :worker, _} =
      Enum.find(children, fn {id, _, _, _} -> id == ExFdbmonitor.Worker end)
    assert is_pid(worker_pid_before)

    # ── Phase 2: After leave() on node3 ──
    :ok = :rpc.call(node3, ExFdbmonitor, :leave, [])

    # Worker is :undefined in supervisor children (terminated, not removed)
    children_after_leave = :rpc.call(node3, Supervisor, :which_children, [ExFdbmonitor.Supervisor])
    {ExFdbmonitor.Worker, worker_state, :worker, _} =
      Enum.find(children_after_leave, fn {id, _, _, _} -> id == ExFdbmonitor.Worker end)
    assert worker_state == :undefined

    # Data still readable from node1 and node2
    for tenant <- [t1, t2] do
      :erlfdb.transactional(tenant, fn tx ->
        assert "data" == :erlfdb.wait(:erlfdb.get(tx, "baseline"))
      end)
    end

    # New writes on node1 succeed and readable from node2
    :erlfdb.transactional(t1, fn tx ->
      :ok = :erlfdb.set(tx, "during_leave", "written")
    end)

    :erlfdb.transactional(t2, fn tx ->
      assert "written" == :erlfdb.wait(:erlfdb.get(tx, "during_leave"))
    end)

    # ── Phase 3: After rejoin() on node3 ──
    :ok = :rpc.call(node3, ExFdbmonitor, :rejoin, [])

    # Worker is running again (new pid)
    children_after_rejoin = :rpc.call(node3, Supervisor, :which_children, [ExFdbmonitor.Supervisor])
    {ExFdbmonitor.Worker, worker_pid_after, :worker, _} =
      Enum.find(children_after_rejoin, fn {id, _, _, _} -> id == ExFdbmonitor.Worker end)
    assert is_pid(worker_pid_after)
    assert worker_pid_after != worker_pid_before

    # Data written during leave is readable from node3
    :erlfdb.transactional(t3, fn tx ->
      assert "written" == :erlfdb.wait(:erlfdb.get(tx, "during_leave"))
    end)

    # Pre-leave data is readable from node3
    :erlfdb.transactional(t3, fn tx ->
      assert "data" == :erlfdb.wait(:erlfdb.get(tx, "baseline"))
    end)

    # New writes from node3 succeed and readable from node1
    :erlfdb.transactional(t3, fn tx ->
      :ok = :erlfdb.set(tx, "after_rejoin", "from_node3")
    end)

    :erlfdb.transactional(t1, fn tx ->
      assert "from_node3" == :erlfdb.wait(:erlfdb.get(tx, "after_rejoin"))
    end)

    # ── Phase 4: Second leave/rejoin cycle ──
    :ok = :rpc.call(node3, ExFdbmonitor, :leave, [])

    children_second_leave = :rpc.call(node3, Supervisor, :which_children, [ExFdbmonitor.Supervisor])
    {ExFdbmonitor.Worker, second_leave_state, :worker, _} =
      Enum.find(children_second_leave, fn {id, _, _, _} -> id == ExFdbmonitor.Worker end)
    assert second_leave_state == :undefined

    :ok = :rpc.call(node3, ExFdbmonitor, :rejoin, [])

    children_second_rejoin = :rpc.call(node3, Supervisor, :which_children, [ExFdbmonitor.Supervisor])
    {ExFdbmonitor.Worker, second_rejoin_pid, :worker, _} =
      Enum.find(children_second_rejoin, fn {id, _, _, _} -> id == ExFdbmonitor.Worker end)
    assert is_pid(second_rejoin_pid)

    # All data still accessible after second cycle
    :erlfdb.transactional(t3, fn tx ->
      assert "data" == :erlfdb.wait(:erlfdb.get(tx, "baseline"))
      assert "written" == :erlfdb.wait(:erlfdb.get(tx, "during_leave"))
      assert "from_node3" == :erlfdb.wait(:erlfdb.get(tx, "after_rejoin"))
    end)
  end
end
