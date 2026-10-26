defmodule Mead.MCP.Server.ListenerConfigurationTest do
  use ExUnit.Case, async: true

  alias Mead.MCP.Server.Configuration

  test "defaults need no token" do
    assert {:ok, %{port: 4040, address: {127, 0, 0, 1}, maximum_connections: 250}} =
             Configuration.listener([])
  end

  test "the listener settings are read whether or not a token is present" do
    expected = %{port: 0, address: {10, 0, 0, 7}, maximum_connections: 8}

    assert {:ok, ^expected} =
             Configuration.listener(port: 0, address: {10, 0, 0, 7}, maximum_connections: 8)

    assert {:ok, ^expected} =
             Configuration.listener(
               token: "t",
               port: 0,
               address: {10, 0, 0, 7},
               maximum_connections: 8
             )
  end

  test "invalid values are refused with the same messages as load/1" do
    assert {:error, "port must be an integer from 0 to 65535"} =
             Configuration.listener(port: 70_000)

    assert {:error, "address must be an IPv4 tuple such as {127, 0, 0, 1}"} =
             Configuration.listener(address: "x")

    assert {:error, "maximum_connections must be a positive integer"} =
             Configuration.listener(maximum_connections: 0)

    assert {:error, "settings must be a keyword list"} = Configuration.listener(%{})
    assert {:error, "unknown setting(s): [:colour]"} = Configuration.listener(colour: 1)
  end
end
