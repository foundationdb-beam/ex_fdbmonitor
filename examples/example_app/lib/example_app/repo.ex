defmodule ExampleApp.Repo do
  use Ecto.Repo, otp_app: :example_app, adapter: Ecto.Adapters.FoundationDB

  use EctoFoundationDB.Migrator

  def migrations() do
    [{0, ExampleApp.Migrations.TemperatureEventIndexes}]
  end
end
