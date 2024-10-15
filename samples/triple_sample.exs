alias ExFdbmonitor.Sandbox

require Logger

Sandbox.start()

cluster_file = Sandbox.cluster_file("triple", 0)

sandbox = Sandbox.Triple.checkout("triple", starting_port: 5050)

IO.puts("Cluster file: #{cluster_file}")

n_nodes_to_stop = IO.gets("Stop nodes: ") |> String.trim() |> String.to_integer()

nodes = Sandbox.nodes(sandbox)

nodes_to_stop = Enum.take(nodes, n_nodes_to_stop)

IO.puts("Stopping #{n_nodes_to_stop} nodes: #{inspect(nodes_to_stop)}...")

for x <- nodes_to_stop, do: :rpc.call(x, :erlang, :halt, [])

_anything = IO.gets("Input anything to stop FDB: ")

Sandbox.Triple.checkin(sandbox)
