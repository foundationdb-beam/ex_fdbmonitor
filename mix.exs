defmodule ExFdbmonitor.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_fdbmonitor,
      description: "A tool for creating FoundationDB clusters",
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [
        test: "test --no-start"
      ],
      package: package(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :global_flags],
      mod: {ExFdbmonitor.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:global_flags, "~> 1.0"},
      {:erlexec, "~> 2.0"},
      {:local_cluster, "~> 2.0"},
      {:erlfdb, "~> 0.2"},
      {:ex_doc, "~> 0.16", only: :dev, runtime: false}

      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
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
