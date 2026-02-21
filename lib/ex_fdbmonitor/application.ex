require Logger

defmodule ExFdbmonitor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    worker =
      if worker?(),
        do: [
          ExFdbmonitor.Worker
        ],
        else: []

    children =
      [{DynamicSupervisor, name: ExFdbmonitor.DynamicSupervisor, strategy: :one_for_one}] ++
        worker

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ExFdbmonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp worker?() do
    case {Application.fetch_env(:ex_fdbmonitor, :etc_dir),
          Application.fetch_env(:ex_fdbmonitor, :run_dir)} do
      {{ok, _}, {ok, _}} ->
        true

      _ ->
        Logger.warning("""
        ExFdbmonitor starting without running fdbmonitor. At minimum, you \
        should define `:etc_dir` and `:run_dir`, but you should also consider \
        adding a `:bootstrap` config.
        """)

        false
    end
  end
end
