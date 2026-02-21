require Logger

defmodule ExFdbmonitor.FdbCli.Server do
  @moduledoc """
  A DGenServer that serializes fdbcli commands across all nodes.

  Nodes submit fdbcli commands via `exec/1`. The DGenServer processes
  them one at a time, ensuring commands from different nodes don't
  interleave on a cluster that is still being configured.
  """

  use DGenServer

  defstruct []

  @tuid {"ExFdbmonitor.FdbCli.Server", "singleton"}

  def start_link({db, dir}) do
    DGenServer.start_link(__MODULE__, [], name: __MODULE__, tenant: {db, dir})
  end

  @doc """
  Execute `fdbcli_args` through the serialized server.
  """
  def exec(fdbcli_args) do
    DGenServer.call(__MODULE__, {:exec, fdbcli_args})
  end

  # --- DGenServer callbacks ---

  @impl true
  def init([]), do: {:ok, @tuid, %__MODULE__{}}

  @impl true
  def handle_call({:exec, _fdbcli_args}, _from, state) do
    {:lock, state}
  end

  @impl true
  def handle_locked({:call, _from}, {:exec, fdbcli_args}, state) do
    Logger.notice("#{node()} fdbcli server exec #{inspect(fdbcli_args)}")
    {:ok, [stdout: _]} = ExFdbmonitor.Fdbcli.exec(fdbcli_args)
    {:reply, :ok, state}
  end
end
