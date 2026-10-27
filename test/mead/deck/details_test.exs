defmodule Mead.Deck.DetailsTest do
  use ExUnit.Case, async: true

  alias Mead.Deck.Details

  describe "lines/1" do
    test "renders the arguments as sorted key: value strings" do
      assert Details.lines(%{"b" => "two", "a" => "one"}) == ["a: one", "b: two"]
    end

    test "a non-map argument becomes a single arguments line" do
      assert Details.lines("/a") == ["arguments: /a"]
    end
  end

  describe "items/1" do
    test "keeps the raw key and value and adds a label" do
      assert Details.items(%{"path" => "/tmp/a"}) == [
               %{"key" => "path", "value" => "/tmp/a", "label" => "Path"}
             ]
    end

    test "turns a snake_case key into a spaced label" do
      assert [%{"label" => "Target folder"}] = Details.items(%{"target_folder" => "x y"})
    end

    test "adds a display only when the value is a snake_case identifier" do
      assert [%{"key" => "action", "value" => "move_to_trash", "display" => "Move to trash"}] =
               Details.items(%{"action" => "move_to_trash"})

      assert [item] = Details.items(%{"note" => "Move_to_Trash please"})
      refute Map.has_key?(item, "display")

      assert [item] = Details.items(%{"count" => 3})
      refute Map.has_key?(item, "display")
      assert item["value"] == "3"
    end

    test "sorts like lines/1 and handles a non-map argument" do
      assert Enum.map(Details.items(%{"b" => "2", "a" => "1"}), & &1["key"]) == ["a", "b"]

      assert Details.items("/a") == [
               %{"key" => "arguments", "value" => "/a", "label" => "Arguments"}
             ]
    end

    test "cuts every value at 2000 characters, like the lines" do
      long = String.duplicate("x", 3_000)
      assert [%{"value" => value}] = Details.items(%{"k" => long})
      assert String.length(value) == 2_000
      assert [line] = Details.lines(%{"k" => long})
      assert line == "k: " <> value
    end

    test "a key that is not valid text still yields a label" do
      assert [%{"key" => key, "label" => label}] = Details.items(%{<<255>> => "v"})
      assert is_binary(key) and is_binary(label)
    end
  end
end
