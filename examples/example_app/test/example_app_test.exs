defmodule ExampleAppTest do
  use ExampleApp.TenantCase
  alias ExampleApp.TemperatureEvent
  alias ExampleApp.Repo

  test "greets the world", context do
    tenant = context[:tenant]

    event =
      Repo.insert!(
        %TemperatureEvent{kelvin: 13.37, site: "L2", recorded_at: NaiveDateTime.utc_now()},
        prefix: tenant
      )

    assert %TemperatureEvent{site: "L2"} = event

    assert ^event = Repo.get_by!(TemperatureEvent, [site: "L2"], prefix: tenant)
  end
end
