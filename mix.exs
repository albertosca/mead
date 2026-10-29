defmodule Mead.MixProject do
  use Mix.Project

  def project do
    [
      app: :mead,
      version: "0.2.1",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 93]],
      description:
        "Runtime for LLM-backed assistants on Elixir/OTP: supervised sessions, a local/cloud model router, and an MCP client and server.",
      package: package(),
      docs: docs(),
      source_url: "https://github.com/albertosca/mead",
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/albertosca/mead"},
      files: ~w(lib mix.exs README.md README.pt.md LICENSE docs/ARCHITECTURE.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "README.pt.md",
        "docs/ARCHITECTURE.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "LICENSE"
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Mead.Application, []}]
  end

  defp deps do
    [
      {:bandit, "~> 1.14"},
      {:req, "~> 0.7.5"},
      {:telemetry, "~> 1.4"},
      {:plug, "~> 1.20"},
      {:websock_adapter, "~> 0.5"},
      {:mint_web_socket, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]
end
