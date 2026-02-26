import Config

config :ex_fdbmonitor,
  bootstrap: [
    cluster: [
      coordinator_addr: "127.0.0.1"
    ],
    conf: [
      data_dir: ".ex_fdbmonitor/dev/data",
      log_dir: ".ex_fdbmonitor/dev/log",
      storage_engine: "ssd-2",
      fdbservers: [
        [port: 5000]
      ]
    ]
  ]

config :ex_fdbmonitor,
  etc_dir: ".ex_fdbmonitor/dev/etc",
  run_dir: ".ex_fdbmonitor/dev/run"
