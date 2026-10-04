defmodule ExFdbmonitor.Integration.LegacyUpgradeCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias ExFdbmonitor.Sandbox
  alias ExFdbmonitor.Sandbox.Single

  setup do
    sandbox = Single.checkout("legacy-integ", starting_port: 5700)

    on_exit(fn ->
      Single.checkin(sandbox, drop?: true)
    end)

    [nodes: Sandbox.nodes(sandbox), sandbox: sandbox]
  end
end

defmodule ExFdbmonitor.Integration.LegacyUpgradeTest do
  alias ExFdbmonitor.Sandbox
  use ExFdbmonitor.Integration.LegacyUpgradeCase

  @tag timeout: :infinity
  test "a node bootstrapped before MgmtServer registers itself on restart", context do
    [node1] = context[:nodes]

    {:ok, machine_id} = :rpc.call(node1, ExFdbmonitor.MgmtServer, :get_machine_id, [node1])

    # A cluster bootstrapped before MgmtServer existed has no MgmtServer
    # state, so no node is registered in it.
    db = :erlfdb.open(Sandbox.cluster_file(node1))
    :ok = :erlfdb_directory.remove(db, :erlfdb_directory.root(), "ex_fdbmonitor")

    # Not a fresh bootstrap: the conf and data are already there.
    :ok = :rpc.call(node1, Application, :stop, [:ex_fdbmonitor])
    {:ok, _} = :rpc.call(node1, Application, :ensure_all_started, [:ex_fdbmonitor])

    # It took the machine id in its own conf.
    assert {:ok, ^machine_id} =
             :rpc.call(node1, ExFdbmonitor.MgmtServer, :get_machine_id, [node1])

    # Adopting again is harmless; another name cannot claim the machine.
    assert :ok = :rpc.call(node1, ExFdbmonitor.MgmtServer, :adopt_node, [machine_id, node1])

    assert {:error, {:machine_id_taken, ^node1}} =
             :rpc.call(node1, ExFdbmonitor.MgmtServer, :adopt_node, [machine_id, :renamed@host])

    # And the database is usable.
    :erlfdb.transactional(db, fn tx -> :ok = :erlfdb.set(tx, "after", "upgrade") end)
    assert "upgrade" == :erlfdb.transactional(db, &:erlfdb.wait(:erlfdb.get(&1, "after")))
  end
end
