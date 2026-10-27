defmodule Mead.ReadmeInstallTest do
  use ExUnit.Case, async: true

  @version Mix.Project.config()[:version]
  @pages ["README.md", "README.pt.md", "guide/en/quickstart.md", "guide/pt/quickstart.md"]

  # Hex is the main way to install mead, so the requirement every page tells people to write must
  # accept the version this package ships.
  test "every install snippet asks for a version this package satisfies" do
    for page <- @pages do
      assert [_, requirement] = Regex.run(~r/\{:mead, "([^"]+)"\}/, File.read!(page)),
             "#{page} must show the Hex dependency"

      assert Version.match?(@version, requirement),
             "#{page} asks for #{requirement}, but the package is #{@version}"
    end
  end

  test "the READMEs carry the Hex version badge" do
    for readme <- ["README.md", "README.pt.md"] do
      assert File.read!(readme) =~ "img.shields.io/hexpm/v/mead"
    end
  end
end
