defmodule AshUi.MixProject do
  use Mix.Project

  @source_url "https://github.com/hyperbob-labs/ash_ui"

  def project do
    [
      app: :ash_ui,
      version: "0.1.0",
      elixir: "~> 1.19",
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AshUi.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, ash_version("~> 3.36")},
      {:spark, "~> 2.4 and >= 2.4.1"},
      {:jason, "~> 1.2"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:simple_sat, "~> 0.1", only: :test}
    ]
  end

  # The Ash this fork builds against, as the Ash libraries choose theirs (ash_sqlite, ash_ai):
  # `local` (the default here) is the Ash fork beside this checkout, `../ash`, whose
  # relationship windows the reload index reads; `main` is upstream's main; a version is hex's.
  defp ash_version(default_version) do
    case System.get_env("ASH_VERSION", "local") do
      "local" -> [path: "../ash", override: true]
      "hex" -> default_version
      "main" -> [git: "https://github.com/ash-project/ash.git", override: true]
      version -> "~> #{version}"
    end
  end

  defp description do
    "User interfaces built from Ash resources: a screen is a resource with a row per session."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      maintainers: ["bob@hyperbob.ai"],
      files: [
        "lib",
        ".formatter.exs",
        "mix.exs",
        "README*",
        "CHANGELOG*",
        "LICENSE*",
        "NOTICE*",
        "DESIGN.md"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      assets: %{"images" => "images"},
      extras: ["README.md", "DESIGN.md", "CHANGELOG.md", "LICENSE", "NOTICE"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
