defmodule Mix.Tasks.Compile.MeadNative do
  @moduledoc false
  # Builds c_src/mead_native.c on macOS, where Erlang's :file.sync/1 does not flush the drive's
  # cache (see Mead.Native). Elsewhere there is nothing to build and no C compiler is needed.
  use Mix.Task.Compiler

  @source "c_src/mead_native.c"
  @flags ~w(-O2 -std=gnu11 -Wall -Wextra -Werror -fPIC -shared -undefined dynamic_lookup)

  @impl Mix.Task.Compiler
  def run(_arguments) do
    cond do
      :os.type() != {:unix, :darwin} -> {:noop, []}
      up_to_date?() -> {:noop, []}
      true -> build()
    end
  end

  @impl Mix.Task.Compiler
  def clean do
    File.rm(stamp())
    File.rm(target())
  end

  defp target, do: Path.join([Mix.Project.app_path(), "priv", "mead_native.so"])

  # Written beside the library after a build: a library built for another ERTS, compiler or set of
  # flags is built again, not only one older than its source.
  defp stamp, do: target() <> ".stamp"

  defp fingerprint, do: inspect({:erlang.system_info(:version), compiler_command(), @flags})

  # CC may carry flags of its own, as in "gcc -m64"; an empty one means the default.
  defp compiler_command do
    case "CC" |> System.get_env("") |> String.split() do
      [] -> ["cc"]
      command -> command
    end
  end

  defp up_to_date? do
    case {File.stat(target()), File.stat(@source), File.read(stamp())} do
      {{:ok, built}, {:ok, source}, {:ok, recorded}} ->
        built.mtime >= source.mtime and recorded == fingerprint()

      _missing ->
        false
    end
  end

  defp build do
    File.mkdir_p!(Path.dirname(target()))

    include =
      Path.join([
        to_string(:code.root_dir()),
        "erts-#{:erlang.system_info(:version)}",
        "include"
      ])

    [compiler | compiler_flags] = compiler_command()
    arguments = compiler_flags ++ @flags ++ ["-I", include, @source, "-o", target()]

    case run_compiler(compiler, arguments) do
      {_output, 0} ->
        File.write!(stamp(), fingerprint())
        Mix.shell().info("Compiled #{@source}")
        {:ok, []}

      {output, status} ->
        Mix.raise("""
        mead could not build #{@source} (#{compiler} exited with #{status}):

        #{output}
        """)
    end
  end

  defp run_compiler(compiler, arguments) do
    System.cmd(compiler, arguments, stderr_to_stdout: true)
  rescue
    error in ErlangError ->
      Mix.raise("""
      mead needs a C compiler on macOS to flush writes to the drive (F_FULLFSYNC), and \
      #{compiler} could not be run: #{inspect(error.original)}. \
      Install the Command Line Tools with `xcode-select --install`, or set CC.
      """)
  end
end

defmodule Mead.MixProject do
  use Mix.Project

  def project do
    [
      app: :mead,
      version: "0.3.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:mead_native] ++ Mix.compilers(),
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
      files:
        ~w(lib c_src mix.exs README.md README.pt.md CHANGELOG.md LICENSE docs/ARCHITECTURE.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "README.pt.md",
        "CHANGELOG.md",
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
