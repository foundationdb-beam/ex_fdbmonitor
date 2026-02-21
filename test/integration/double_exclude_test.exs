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
  test "double cluster: exclude 2 of 3 nodes", context do
    [node1, node2, node3] = context[:nodes]

    # Open databases and create tenant
    dbs = for node <- [node1, node2, node3], do: :erlfdb.open(Sandbox.cluster_file(node))
    [db1, _db2, _db3] = dbs
    tenant_name = "dex-test"
    :ok = :erlfdb_tenant_management.create_tenant(db1, tenant_name)
    tenants = for db <- dbs, do: :erlfdb.open_tenant(db, tenant_name)
    [t1, t2, _t3] = tenants

    # ── Phase 1: Baseline (3 nodes healthy) ──
    Logger.notice("Phase 1: writing baseline data")

    :erlfdb.transactional(t1, fn tx ->
      :ok = :erlfdb.set(tx, "baseline", "data")
    end)

    for {tenant, node} <- Enum.zip(tenants, [node1, node2, node3]) do
      :erlfdb.transactional(tenant, fn tx ->
        val = :erlfdb.wait(:erlfdb.get(tx, "baseline"))
        Logger.notice("Phase 1: read from #{node} = #{inspect(val)}")
        assert val == "data"
      end)
    end

    # ── Phase 2: Exclude node3 via leave() ──
    Logger.notice("Phase 2: excluding node3 via leave()")
    :ok = :rpc.call(node3, ExFdbmonitor, :leave, [])
    Logger.notice("Phase 2: node3 excluded successfully")

    :erlfdb.transactional(t1, fn tx ->
      :ok = :erlfdb.set(tx, "after_exclude_1", "still_works")
    end)
    :erlfdb.transactional(t2, fn tx ->
      val = :erlfdb.wait(:erlfdb.get(tx, "after_exclude_1"))
      Logger.notice("Phase 2: read from node2 = #{inspect(val)}")
      assert val == "still_works"
    end)

    # ── Phase 2b: configure single, then coordinators auto ──
    Logger.notice("Phase 2b: running configure single")
    configure_result =
      :rpc.call(node1, ExFdbmonitor.MgmtServer, :exec, [["configure", "single"]])
    log_fdbcli_result("Phase 2b: configure single", configure_result)

    Logger.notice("Phase 2b: setting coordinator to node1 (127.0.0.1:5600)")
    coord_result =
      :rpc.call(node1, ExFdbmonitor.MgmtServer, :exec, [["coordinators", "127.0.0.1:5600"]])
    log_fdbcli_result("Phase 2b: coordinators", coord_result)

    # Confirm cluster still works
    :erlfdb.transactional(t1, fn tx ->
      val = :erlfdb.wait(:erlfdb.get(tx, "baseline"))
      Logger.notice("Phase 2b: read after reconfigure = #{inspect(val)}")
      assert val == "data"
    end)

    # ── Phase 3: Exclude node2 (with wait) ──
    Logger.notice("Phase 3: excluding node2")

    {:ok, machine_id} = :rpc.call(node1, ExFdbmonitor.MgmtServer, :get_machine_id, [node2])
    exclude_result =
      :rpc.call(node1, ExFdbmonitor.MgmtServer, :exec, [
        ["exclude", "locality_machineid:#{machine_id}"]
      ])
    log_fdbcli_result("Phase 3: exclude", exclude_result)

    # Stop node2's worker
    :ok = :rpc.call(node2, Supervisor, :terminate_child, [ExFdbmonitor.Supervisor, ExFdbmonitor.Worker])
    Logger.notice("Phase 3: node2 worker stopped, only node1 remains")

    # Use fdbcli directly on node1 (not MgmtServer, which uses FDB transactions)
    cluster_file = Sandbox.cluster_file(node1)
    status_result = :rpc.call(node1, ExFdbmonitor.Fdbcli, :exec, [cluster_file, ["status"]])
    case status_result do
      {:ok, output} ->
        for {key, lines} <- output do
          Logger.notice("Phase 3 status #{key}:\n#{IO.iodata_to_binary(lines)}")
        end
      other ->
        Logger.notice("Phase 3 status: #{inspect(other)}")
    end

    # Attempt read from node1 with timeout
    read_result = try_with_timeout("READ", fn ->
      :erlfdb.transactional(t1, fn tx ->
        :erlfdb.wait(:erlfdb.get(tx, "baseline"), [{:timeout, 10_000}])
      end)
    end)

    # Attempt write from node1 with timeout
    write_result = try_with_timeout("WRITE", fn ->
      :erlfdb.transactional(t1, fn tx ->
        :erlfdb.set(tx, "after_exclude_2", "one_node_left")
      end)
    end)

    Logger.notice("RESULT: read=#{inspect(read_result)} write=#{inspect(write_result)}")
  end

  defp log_fdbcli_result(label, result) do
    case result do
      {:ok, output} ->
        for {key, lines} <- output do
          Logger.notice("#{label} #{key}:\n#{IO.iodata_to_binary(lines)}")
        end
      {:error, output} when is_list(output) ->
        for {key, lines} <- output do
          Logger.notice("#{label} ERROR #{key}:\n#{IO.iodata_to_binary(lines)}")
        end
      other ->
        Logger.notice("#{label} returned: #{inspect(other)}")
    end
  end

  defp try_with_timeout(label, fun) do
    caller = self()
    ref = make_ref()

    # Use spawn (not Task.async) to avoid linked crash propagation
    pid = spawn(fn ->
      result =
        try do
          {:ok, fun.()}
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      send(caller, {ref, result})
    end)

    receive do
      {^ref, {:ok, val}} ->
        Logger.notice("Phase 3: #{label} SUCCEEDED = #{inspect(val)}")
        {:ok, val}
      {^ref, {:error, reason}} ->
        Logger.notice("Phase 3: #{label} FAILED = #{inspect(reason)}")
        {:error, reason}
    after
      15_000 ->
        Process.exit(pid, :kill)
        Logger.notice("Phase 3: #{label} TIMED OUT")
        :timeout
    end
  end
end
