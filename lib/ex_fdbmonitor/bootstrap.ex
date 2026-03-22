defmodule ExFdbmonitor.Bootstrap do
  @moduledoc false

  @type t :: %__MODULE__{
          cluster_file: String.t(),
          machine_id: String.t() | nil,
          fdbcli_cmds: [[String.t()]],
          redundancy_mode: String.t() | nil,
          fdbserver_ports: [non_neg_integer()]
        }

  defstruct [:cluster_file, :machine_id, :redundancy_mode, fdbcli_cmds: [], fdbserver_ports: []]
end
