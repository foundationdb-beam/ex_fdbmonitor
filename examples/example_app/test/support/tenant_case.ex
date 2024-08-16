defmodule ExampleApp.TenantCase do
  use ExUnit.CaseTemplate
  alias Ecto.UUID
  alias EctoFoundationDB.Sandbox
  alias ExampleApp.Repo

  setup do
    tenant_id = UUID.autogenerate()
    tenant = Sandbox.checkout(Repo, tenant_id, [])

    on_exit(fn ->
      Sandbox.checkin(Repo, tenant_id)
    end)

    {:ok, [tenant_id: tenant_id, tenant: tenant]}
  end
end
