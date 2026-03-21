[
  # DGenServer callbacks are invoked by dgen_server, not directly.
  # Dialyzer can't trace through the callback mechanism.
  {"lib/ex_fdbmonitor/mgmt_server.ex", :no_return},
  {"lib/ex_fdbmonitor/mgmt_server.ex", :unused_fun},

  # erlexec's :exec.run/2 and :exec.run_link/2 are NIFs that dialyzer can't resolve
  {"lib/ex_fdbmonitor/fdbcli.ex", :no_return},
  {"lib/ex_fdbmonitor/fdbdr.ex", :no_return},
  {"lib/ex_fdbmonitor/worker.ex", :no_return},

  # :memsup is from os_mon, an included_application started at runtime
  {"lib/ex_fdbmonitor/application.ex", :unknown_function}
]
