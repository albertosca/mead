defmodule Mead.ReleaseScriptTest do
  use ExUnit.Case, async: true

  @script "scripts/check_release.sh"
  @version Mix.Project.config()[:version]

  defp check(tag), do: System.cmd("bash", [@script, tag], stderr_to_stdout: true)

  test "accepts the tag that matches the version in mix.exs" do
    assert {output, 0} = check("v" <> @version)
    assert output =~ @version
  end

  test "rejects a tag for another version" do
    assert {output, status} = check("v99.0.0")
    assert status != 0
    assert output =~ "does not match"
  end

  test "rejects a tag without the v prefix" do
    assert {output, status} = check(@version)
    assert status != 0
    assert output =~ "must look like"
  end

  test "rejects an empty tag" do
    assert {output, status} = check("")
    assert status != 0
    assert output =~ "must look like"
  end

  test "the release workflow runs the check on tags only and publishes to Hex" do
    workflow = File.read!(".github/workflows/release.yml")

    assert workflow =~ ~r/tags:\s*\["v\*"\]/
    refute workflow =~ "branches:"
    assert workflow =~ "scripts/check_release.sh"
    assert workflow =~ "mix hex.publish --yes"
    assert workflow =~ "secrets.HEX_API_KEY"
  end
end
