defmodule ExampleApp.TemperatureEvent do
  use Ecto.Schema
  @schema_context usetenant: true
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "temperature_events" do
    field(:recorded_at, :naive_datetime_usec)
    field(:kelvin, :float)
    field(:site, :string)
    timestamps()
  end
end
