alias ExFdbmonitor.Fdbdr
alias ExFdbmonitor.Sandbox

require Logger

Sandbox.start()

sandbox = Sandbox.Single

primary_cluster = Sandbox.cluster_file("primary", 0)
secondary_cluster = Sandbox.cluster_file("secondary", 0)

primary =
  sandbox.checkout("primary",
    starting_port: 5050,
    conf_assigns: [dr: [source: secondary_cluster, destination: :self]]
  )

secondary =
  sandbox.checkout("secondary",
    starting_port: 5060,
    conf_assigns: [dr: [source: primary_cluster, destination: :self]]
  )

# fdbdr start -s .ex_fdbmonitor/primary.0/etc/fdb.cluster -d .ex_fdbmonitor/secondary.0/etc/fdb.cluster
{:ok, result} = Fdbdr.exec(:start, primary_cluster, secondary_cluster)

Logger.notice(result[:stdout])

:timer.sleep(5000)

{:ok, result} = Fdbdr.exec(:status, primary_cluster, secondary_cluster)

Logger.notice(result[:stdout])

:timer.sleep(100)

_anything = IO.gets("Input anything to tear down the DBs: ")

sandbox.checkin(primary, drop?: true)
sandbox.checkin(secondary, drop?: true)
