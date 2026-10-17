defmodule Mead.UUIDTest do
  use ExUnit.Case, async: true

  @version_four_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  test "generate/0 returns a lowercase UUID v4 string" do
    assert Mead.UUID.generate() =~ @version_four_pattern
  end

  test "generate/0 returns distinct values" do
    uuids = for _index <- 1..1_000, do: Mead.UUID.generate()

    assert length(Enum.uniq(uuids)) == 1_000
  end
end
