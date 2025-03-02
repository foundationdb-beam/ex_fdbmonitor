import Config

config :example_app, MyApp.Repo,
  open_db: &ExFdbmonitor.open_db/1

config :ex_fdbmonitor,
  etc_dir: ".example_app/dev/fdb/etc",
  run_dir: ".example_app/dev/fdb/run"

config :ex_fdbmonitor,
  bootstrap: [
    cluster: [
      coordinator_addr: "127.0.0.1"
    ],
    conf: [
      data_dir: ".example_app/dev/fdb/data",
      log_dir: ".example_app/dev/fdb/log",
      fdbservers: [
        [port: 5000]
      ]
    ],
    fdbcli: ~w[configure new single ssd-redwood-1]
  ]
