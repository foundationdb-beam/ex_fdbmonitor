defmodule ExampleApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :example_app,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ExampleApp.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:erlfdb, git: "https://github.com/foundationdb-beam/erlfdb.git", branch: "main", override: true},
      {:ecto_foundationdb, git: "https://github.com/foundationdb-beam/ecto_foundationdb.git", branch: "main"},
      #{:ex_fdbmonitor, git: "https://github.com/foundationdb-beam/ex_fdbmonitor.git", branch: "main"}
      {:ex_fdbmonitor, path: "../..", only: :dev}
    ]
  end
end
