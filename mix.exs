defmodule Terminalwire.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/terminalwire/elixir"

  def project do
    [
      app: :terminalwire,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Terminalwire",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"]],
      # `mix test --cover` fails the build if total coverage drops below this
      # floor. Standalone `mix test` (no corpus) is ~86%; the corpus matrix run is
      # higher. Margin below the standalone actual absorbs cross-version variance.
      # Raise as coverage improves; never lower silently.
      test_coverage: [summary: [threshold: 85]]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Terminalwire.Application, []}]
  end

  defp deps do
    [
      {:msgpax, "~> 2.3"},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Terminalwire v2 server for Elixir — the layer between your WebSocket " <>
      "endpoint (Phoenix/Plug/Cowboy) and your CLI/terminal code. Stream a " <>
      "command-line app from your server with no web API."
  end

  defp package do
    [
      maintainers: ["Brad Gessler"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
