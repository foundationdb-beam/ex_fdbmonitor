import Config

config :example_app, ExampleApp.Repo, open_db: &EctoFoundationDB.Sandbox.open_db/0
