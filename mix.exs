defmodule Mead.MixProject do
  use Mix.Project

  def project do
    [
      app: :mead,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Mead.Application, []}]
  end

  defp deps do
    [
      {:bandit, "~> 1.13"},
      {:req, "~> 0.7.5"},
      {:telemetry, "~> 1.4"},
      {:plug, "~> 1.20"},
      {:websock_adapter, "~> 0.5"},
      {:mint_web_socket, "~> 1.0", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]
end
