defmodule AshUiPhoenix.MixProject do
  use Mix.Project

  @source_url "https://github.com/hyperbob-labs/ash_ui"

  def project do
    [
      app: :ash_ui_phoenix,
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

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ash, ash_version("~> 3.36")},
      sibling(:ash_ui, "../.."),
      {:ash_authentication_phoenix, "~> 2.0", optional: true},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:bandit, "~> 1.6", only: :test},
      {:simple_sat, "~> 0.1", only: :test}
    ]
  end

  defp description do
    "Phoenix and LiveView transport adapter for AshUi resources."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      maintainers: ["bob@hyperbob.ai"],
      files: [
        "lib",
        "priv/static",
        ".formatter.exs",
        "mix.exs",
        "README*",
        "CHANGELOG*",
        "LICENSE*",
        "NOTICE*"
      ]
    ]
  end

  # Inside this repository the sibling packages resolve by path. Set
  # ASH_UI_HEX=1 to resolve them from Hex for `mix hex.build` and `mix hex.publish`.
  defp sibling(app, path, opts \\ []) do
    if System.get_env("ASH_UI_HEX"),
      do: {app, "~> 0.1.0", opts},
      else: {app, Keyword.put(opts, :path, path)}
  end

  # The Ash the root project builds against (its mix.exs: ASH_VERSION, the Ash fork beside the checkout by default).
  defp ash_version(default_version) do
    case System.get_env("ASH_VERSION", "local") do
      "local" -> [path: "../../../ash", override: true]
      "hex" -> default_version
      "main" -> [git: "https://github.com/ash-project/ash.git", override: true]
      version -> "~> #{version}"
    end
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE", "NOTICE"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
