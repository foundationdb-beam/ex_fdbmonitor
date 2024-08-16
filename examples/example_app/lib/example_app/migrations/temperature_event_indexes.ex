defmodule ExampleApp.Migrations.TemperatureEventIndexes do
  use EctoFoundationDB.Migration
  alias ExampleApp.TemperatureEvent

  def change() do
    [
      create(index(TemperatureEvent, [:site])),
      create(index(TemperatureEvent, [:recorded_at]))
    ]
  end
end
