defmodule Mead.MCP.CatalogTest do
  use ExUnit.Case, async: true

  import Mead.TestHelpers

  alias Mead.MCP.Catalog

  @schema %{"type" => "object"}

  setup do
    name = :"catalog_#{System.unique_integer([:positive])}"
    servers = [%{name: :one, transport: {:stdio, command: "x", arguments: []}, tools: %{}}]
    start_supervised!({Catalog, name: name, servers: servers})

    %{catalog: name, servers: servers}
  end

  defp tool(name), do: %{name: name, description: "about #{name}", input_schema: @schema}

  defp names(catalog) do
    {:ok, entries, _servers} = Catalog.snapshot(catalog)
    entries |> Enum.map(&{&1.server, &1.name}) |> Enum.sort()
  end

  defp idle_process do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  test "starts empty and returns the stored configuration", %{catalog: catalog, servers: servers} do
    assert Catalog.snapshot(catalog) == {:ok, [], servers}
  end

  test "registered tools come back as entries tagged with their server", %{catalog: catalog} do
    owner = idle_process()
    :ok = Catalog.register(catalog, :one, owner, [tool("a"), tool("b")])

    {:ok, entries, _servers} = Catalog.snapshot(catalog)

    assert Enum.sort_by(entries, & &1.name) == [
             %{server: :one, name: "a", description: "about a", input_schema: @schema},
             %{server: :one, name: "b", description: "about b", input_schema: @schema}
           ]
  end

  test "registering a server again replaces its tools instead of adding to them", %{
    catalog: catalog
  } do
    owner = idle_process()
    :ok = Catalog.register(catalog, :one, owner, [tool("a")])
    :ok = Catalog.register(catalog, :one, owner, [tool("b")])

    assert names(catalog) == [one: "b"]
  end

  test "servers are kept apart", %{catalog: catalog} do
    :ok = Catalog.register(catalog, :one, idle_process(), [tool("a")])
    :ok = Catalog.register(catalog, :two, idle_process(), [tool("a")])

    assert names(catalog) == [one: "a", two: "a"]
  end

  test "unregistering removes only that server, and is harmless twice", %{catalog: catalog} do
    :ok = Catalog.register(catalog, :one, idle_process(), [tool("a")])
    :ok = Catalog.register(catalog, :two, idle_process(), [tool("b")])

    assert :ok = Catalog.unregister(catalog, :one)
    assert :ok = Catalog.unregister(catalog, :one)
    assert names(catalog) == [two: "b"]
  end

  test "a server whose owner dies, even by being killed, loses its tools", %{catalog: catalog} do
    owner = idle_process()
    :ok = Catalog.register(catalog, :one, owner, [tool("a")])

    Process.exit(owner, :kill)

    wait_until(fn -> names(catalog) == [] end)
  end

  test "a new owner registered before the old one's death is noticed keeps its tools", %{
    catalog: catalog
  } do
    old_owner = idle_process()
    new_owner = idle_process()
    :ok = Catalog.register(catalog, :one, old_owner, [tool("old")])
    :ok = Catalog.register(catalog, :one, new_owner, [tool("new")])

    Process.exit(old_owner, :kill)
    Process.sleep(50)

    assert names(catalog) == [one: "new"]
  end

  test "the snapshot of a catalog that is not running is unavailable, not an exception" do
    assert Catalog.snapshot(:no_such_catalog) == :unavailable
  end
end
