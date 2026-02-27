defmodule ExFdbmonitor.Integration.DoubleExcludeCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias ExFdbmonitor.Sandbox
  alias ExFdbmonitor.Sandbox.Double

  setup do
    sandbox = Double.checkout("dex-integ", starting_port: 5600)

    on_exit(fn ->
      Double.checkin(sandbox, drop?: true)
    end)

    [nodes: Sandbox.nodes(sandbox), sandbox: sandbox]
  end
end

defmodule ExFdbmonitor.Integration.DoubleExcludeTest do
  require Logger
  alias ExFdbmonitor.Sandbox
  use ExFdbmonitor.Integration.DoubleExcludeCase

  @tag timeout: :infinity
  test "scale down double to single, then scale back up", context do
    [node1, node2, node3] = context[:nodes]

    # Open databases
    dbs = for node <- [node1, node2, node3], do: :erlfdb.open(Sandbox.cluster_file(node))
    [db1, _db2, _db3] = dbs

    # ── Phase 1: Baseline (3 nodes, double redundancy) ──
    Logger.notice("Phase 1: writing baseline data")

    :erlfdb.transactional(db1, fn tx ->
      :ok = :erlfdb.set(tx, "baseline", "data")
    end)

    for {db, node} <- Enum.zip(dbs, [node1, node2, node3]) do
      :erlfdb.transactional(db, fn tx ->
        val = :erlfdb.wait(:erlfdb.get(tx, "baseline"))
        Logger.notice("Phase 1: read from #{node} = #{inspect(val)}")
        assert val == "data"
      end)
    end

    # ── Phase 2: Scale down to single ──
    Logger.notice("Phase 2: scale_down, removing node2 and node3")
    {:ok, removed} =
      :rpc.call(node1, ExFdbmonitor.MgmtServer, :scale_down, [[node2, node3]])
    Logger.notice("Phase 2: scale_down returned, removed: #{inspect(removed)}")

    # Stop workers on removed nodes
    for node <- [node2, node3] do
      :ok = :rpc.call(node, Supervisor, :terminate_child, [ExFdbmonitor.Supervisor, ExFdbmonitor.Worker])
    end
    Logger.notice("Phase 2: workers stopped on node2 and node3")

    # Verify reads/writes on node1
    :erlfdb.transactional(db1, fn tx ->
      val = :erlfdb.wait(:erlfdb.get(tx, "baseline"))
      Logger.notice("Phase 2: read baseline from node1 = #{inspect(val)}")
      assert val == "data"
    end)

    :erlfdb.transactional(db1, fn tx ->
      :ok = :erlfdb.set(tx, "while_single", "node1_only")
    end)

    :erlfdb.transactional(db1, fn tx ->
      val = :erlfdb.wait(:erlfdb.get(tx, "while_single"))
      Logger.notice("Phase 2: read while_single from node1 = #{inspect(val)}")
      assert val == "node1_only"
    end)

    # ── Phase 3: Scale back up to double ──
    Logger.notice("Phase 3: restarting workers on node2 and node3")
    for node <- [node2, node3] do
      {:ok, _} = :rpc.call(node, Supervisor, :restart_child, [ExFdbmonitor.Supervisor, ExFdbmonitor.Worker])
    end

    Logger.notice("Phase 3: scale_up to double, including node2 and node3")
    :ok = :rpc.call(node1, ExFdbmonitor.MgmtServer, :scale_up, ["double", [node2, node3]])
    Logger.notice("Phase 3: scale_up returned")

    # Verify all data accessible from all 3 nodes
    for {db, node} <- Enum.zip(dbs, [node1, node2, node3]) do
      :erlfdb.transactional(db, fn tx ->
        val1 = :erlfdb.wait(:erlfdb.get(tx, "baseline"))
        val2 = :erlfdb.wait(:erlfdb.get(tx, "while_single"))
        Logger.notice("Phase 3: #{node} baseline=#{inspect(val1)} while_single=#{inspect(val2)}")
        assert val1 == "data"
        assert val2 == "node1_only"
      end)
    end

    # Write from node3, read from node1
    [_db1, _db2, db3] = dbs

    :erlfdb.transactional(db3, fn tx ->
      :ok = :erlfdb.set(tx, "after_scale_up", "from_node3")
    end)

    :erlfdb.transactional(db1, fn tx ->
      val = :erlfdb.wait(:erlfdb.get(tx, "after_scale_up"))
      Logger.notice("Phase 3: read after_scale_up from node1 = #{inspect(val)}")
      assert val == "from_node3"
    end)
  end
end
