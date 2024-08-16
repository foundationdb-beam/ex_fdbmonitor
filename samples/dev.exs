alias ExFdbmonitor.Sandbox

require Logger

Sandbox.start()

cluster_file = Sandbox.cluster_file("dev", 0)

sandbox = Sandbox.Single.checkout("dev", starting_port: 5050)

IO.puts("Cluster file: #{cluster_file}")
_anything = IO.gets("Input anything to stop FDB: ")

Sandbox.Single.checkin(sandbox)
