defmodule ExFdbmonitor.Integration.MgmtServerCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias ExFdbmonitor.Sandbox
  alias ExFdbmonitor.Sandbox.Double

  setup do
    sandbox = Double.checkout("mgmt-integ", starting_port: 5400)

    on_exit(fn ->
      Double.checkin(sandbox, drop?: true)
    end)

    [nodes: Sandbox.nodes(sandbox), sandbox: sandbox]
  end
end

defmodule ExFdbmonitor.Integration.MgmtServerTest do
  use ExFdbmonitor.Integration.MgmtServerCase

  @tag timeout: :infinity
  test "MgmtServer error handling and exec", context do
    [node1, node2, node3] = context[:nodes]

    # exclude(:bogus) returns error from each node
    for node <- [node1, node2, node3] do
      result = :rpc.call(node, ExFdbmonitor.MgmtServer, :exclude, [:bogus])
      assert {:error, {:unknown_node, :bogus}} == result
    end

    # include(:nonexistent) returns error from each node
    for node <- [node1, node2, node3] do
      result = :rpc.call(node, ExFdbmonitor.MgmtServer, :include, [:nonexistent])
      assert {:error, {:unknown_node, :nonexistent}} == result
    end

    # get_machine_id(:bogus) returns :error
    for node <- [node1, node2, node3] do
      result = :rpc.call(node, ExFdbmonitor.MgmtServer, :get_machine_id, [:bogus])
      assert :error == result
    end

    # get_machine_id for each registered node returns consistent values from any node
    for target_node <- [node1, node2, node3] do
      results =
        for caller_node <- [node1, node2, node3] do
          :rpc.call(caller_node, ExFdbmonitor.MgmtServer, :get_machine_id, [target_node])
        end

      assert length(Enum.uniq(results)) == 1
      {:ok, mid} = hd(results)
      assert is_binary(mid)
    end

    # exec(["status"]) returns {:ok, _} with stdout
    result = :rpc.call(node1, ExFdbmonitor.MgmtServer, :exec, [["status"]])
    assert {:ok, [stdout: stdout]} = result
    assert is_list(stdout)
    output = IO.iodata_to_binary(stdout)
    assert String.contains?(output, "Configuration:")
  end
end
