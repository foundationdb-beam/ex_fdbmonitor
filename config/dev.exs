import Config

config :ex_fdbmonitor,
  bootstrap: [
    cluster: [
      coordinator_addr: "127.0.0.1"
    ],
    conf: [
      data_dir: ".ex_fdbmonitor/dev/data",
      log_dir: ".ex_fdbmonitor/dev/log",
      fdbservers: [
        [port: 5000]
      ]
    ],
    fdbcli: ~w[configure new single ssd tenant_mode=required_experimental]
  ]

config :ex_fdbmonitor,
  etc_dir: ".ex_fdbmonitor/dev/etc",
  run_dir: ".ex_fdbmonitor/dev/run"
