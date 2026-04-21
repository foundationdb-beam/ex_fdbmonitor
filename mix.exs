defmodule ExFdbmonitor.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_fdbmonitor,
      description: "A tool for creating FoundationDB clusters",
      version: "0.2.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs",
        plt_add_apps: [:erlexec, :dgen, :os_mon]
      ],
      package: package(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :eex, :global_flags],
      included_applications: [:os_mon],
      mod: {ExFdbmonitor.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:global_flags, "~> 1.0"},
      {:erlexec, "~> 2.0"},
      {:local_cluster, "~> 2.0"},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.16", only: :dev, runtime: false},
      {:erlfdb, "~> 1.0"},
      {:dgen, github: "foundationdb-beam/dgen"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/foundationdb-beam/ex_fdbmonitor"
      }
    ]
  end

  defp aliases do
    [
      test: "test --no-start",
      lint: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "credo --all --strict",
        "dialyzer --format short"
      ]
    ]
  end

  defp docs do
    [
      main: "ExFdbmonitor",
      source_url: "https://github.com/foundationdb-beam/ex_fdbmonitor",
      extras: [
        "examples/example_app/README.md": [
          filename: "example-app"
        ]
      ]
    ]
  end
end
