defmodule Mead.MCP.PolicyTest do
  use ExUnit.Case, async: true

  alias Mead.MCP.Policy

  @schema %{"type" => "object"}

  defp entry(server, name, extra \\ %{}) do
    Map.merge(
      %{server: server, name: name, description: "about #{name}", input_schema: @schema},
      extra
    )
  end

  defp server(name, tools),
    do: %{name: name, transport: {:stdio, command: "x", arguments: []}, tools: tools}

  defp servers do
    [
      server(:filesystem, %{"read_file" => :read, "write_file" => :effect}),
      server(:github, %{"search" => :read})
    ]
  end

  defp entries do
    [
      entry(:filesystem, "read_file"),
      entry(:filesystem, "write_file"),
      entry(:filesystem, "delete_everything"),
      entry(:github, "search")
    ]
  end

  defp names(tools), do: tools |> Enum.map(& &1.name) |> Enum.sort()

  describe "visible_tools/3" do
    test "shows only the listed read tools by default, named server__tool" do
      assert names(Policy.visible_tools(entries(), servers(), [])) ==
               ["filesystem__read_file", "github__search"]
    end

    test "carries the description, schema, server, tool, and class" do
      tool =
        entries()
        |> Policy.visible_tools(servers(), [])
        |> Enum.find(&(&1.name == "github__search"))

      assert tool == %{
               name: "github__search",
               description: "about search",
               input_schema: @schema,
               server: :github,
               tool: "search",
               class: :read
             }
    end

    test "shows effect tools only when the turn opts in with tools: :effect" do
      assert names(Policy.visible_tools(entries(), servers(), tools: :effect)) ==
               ["filesystem__read_file", "filesystem__write_file", "github__search"]
    end

    test "any other value of tools: behaves as the default" do
      for value <- [:read, :none, :everything, "effect", nil, 1, [:effect]] do
        assert names(Policy.visible_tools(entries(), servers(), tools: value)) ==
                 ["filesystem__read_file", "github__search"]
      end
    end

    test "a tool the server offers and the configuration does not list is invisible" do
      refute "filesystem__delete_everything" in names(
               Policy.visible_tools(entries(), servers(), tools: :effect)
             )
    end

    test "the server's own annotations never change the class or the visibility" do
      lying = [
        entry(:filesystem, "delete_everything", %{annotations: %{"readOnlyHint" => true}}),
        entry(:filesystem, "write_file", %{annotations: %{"readOnlyHint" => true}})
      ]

      assert Policy.visible_tools(lying, servers(), []) == []

      assert names(Policy.visible_tools(lying, servers(), tools: :effect)) == [
               "filesystem__write_file"
             ]
    end

    test "a tool the configuration lists and the server does not offer is simply absent" do
      assert names(Policy.visible_tools([entry(:github, "search")], servers(), tools: :effect)) ==
               ["github__search"]
    end

    test "two servers may expose the same tool name" do
      servers = [server(:a, %{"search" => :read}), server(:b, %{"search" => :read})]
      entries = [entry(:a, "search"), entry(:b, "search")]

      assert names(Policy.visible_tools(entries, servers, [])) == ["a__search", "b__search"]
    end

    test "a tool whose combined name the model cannot use is invisible" do
      servers = [server(:s, %{"has.dot" => :read, "ok_name" => :read, "x" => :read})]
      long = String.duplicate("a", 63)
      servers = [%{hd(servers) | tools: Map.put(hd(servers).tools, long, :read)}]
      entries = [entry(:s, "has.dot"), entry(:s, "ok_name"), entry(:s, long)]

      assert names(Policy.visible_tools(entries, servers, [])) == ["s__ok_name"]
    end

    test "no entries, or no servers, shows nothing" do
      assert Policy.visible_tools([], servers(), []) == []
      assert Policy.visible_tools(entries(), [], []) == []
    end
  end

  describe "authorize/4" do
    test "allows a listed read tool" do
      assert Policy.authorize("filesystem__read_file", entries(), servers(), []) ==
               {:ok, %{server: :filesystem, tool: "read_file", class: :read}}
    end

    test "refuses an effect tool without the opt-in, and allows it with" do
      assert Policy.authorize("filesystem__write_file", entries(), servers(), []) ==
               {:error, :not_allowed}

      assert Policy.authorize("filesystem__write_file", entries(), servers(), tools: :everything) ==
               {:error, :not_allowed}

      assert Policy.authorize("filesystem__write_file", entries(), servers(), tools: :effect) ==
               {:ok, %{server: :filesystem, tool: "write_file", class: :effect}}
    end

    test "a tool name containing the separator still resolves on the first split" do
      servers = [server(:fs, %{"a__b" => :read})]

      assert Policy.authorize("fs__a__b", [entry(:fs, "a__b")], servers, []) ==
               {:ok, %{server: :fs, tool: "a__b", class: :read}}
    end

    test "everything the model was not shown is an unknown tool" do
      unknown = [
        "read_file",
        "filesystem",
        "filesystem__",
        "__read_file",
        "ghost__read_file",
        "filesystem__delete_everything",
        "filesystem__ghost",
        "github__read_file",
        "FILESYSTEM__read_file",
        "",
        "filesystem__read_file\n",
        "filesystem__read file"
      ]

      for name <- unknown do
        assert Policy.authorize(name, entries(), servers(), tools: :effect) ==
                 {:error, :unknown_tool},
               "expected #{inspect(name)} to be unknown"
      end
    end

    test "a listed tool the server no longer offers is unknown, not allowed" do
      assert Policy.authorize(
               "filesystem__write_file",
               [entry(:filesystem, "read_file")],
               servers(),
               []
             ) ==
               {:error, :unknown_tool}
    end

    test "a name that is not a binary is unknown and does not raise" do
      for value <- [nil, :atom, 1, %{}, ["filesystem__read_file"]] do
        assert Policy.authorize(value, entries(), servers(), []) == {:error, :unknown_tool}
      end
    end

    test "a name that fails the model-name rules cannot be executed even if listed" do
      servers = [server(:s, %{"has.dot" => :read})]

      assert Policy.authorize("s__has.dot", [entry(:s, "has.dot")], servers, []) ==
               {:error, :unknown_tool}
    end

    test "never creates an atom from the name it is given" do
      name = "filesystem__never_seen_#{System.unique_integer([:positive])}"
      before_count = :erlang.system_info(:atom_count)
      Policy.authorize(name, entries(), servers(), [])
      assert :erlang.system_info(:atom_count) - before_count < 5
    end
  end
end
