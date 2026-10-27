defmodule Mead.ReadmeBadgeTest do
  use ExUnit.Case, async: true

  # The coverage badge is a static image, so the only thing that keeps it honest is the CI gate:
  # the number on it must be the threshold `mix test --cover` fails below.
  test "the coverage badge in every README states the coverage gate" do
    [_, threshold] = Regex.run(~r/threshold: (\d+)/, File.read!("mix.exs"))

    for readme <- ["README.md", "README.pt.md"] do
      assert File.read!(readme) =~ "badge/coverage-#{threshold}%25%2B-",
             "#{readme} must show the #{threshold}% coverage gate"
    end
  end
end
