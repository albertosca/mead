defmodule Mead.MCP.HubReadyTest do
  use ExUnit.Case, async: true

  alias Mead.MCP.Catalog
  alias Mead.MCP.Hub
  alias Mead.Test.FakeTransport

  @moduletag :capture_log

  defp start_hub(servers) do
    name = :"hub_#{System.unique_integer([:positive])}"

    options = [
      name: name,
      servers: for(server <- servers, do: {server, [transport: {:stdio, command: "unused"}]}),
      transports: %{stdio: {FakeTransport, [test_pid: self()]}},
      reconnect_delays: [10],
      handshake_timeout: 10_000
    ]

    start_supervised!(Supervisor.child_spec({Hub, options}, id: name))
    name
  end

  defp connect(tools) do
    receive do
      {:transport_started, transport} -> FakeTransport.complete_handshake(transport, tools)
    after
      10_000 -> raise "no transport was started"
    end
  end

  test "a hub with no servers is ready at once" do
    hub = start_hub([])
    assert Hub.await_ready(1_000, hub) == :ok
  end

  test "waiting gives up within the bound when a server never registers" do
    hub = start_hub([:silent])

    {elapsed, result} = :timer.tc(fn -> Hub.await_ready(200, hub) end, :millisecond)

    assert result == :timeout
    assert elapsed >= 200 and elapsed < 1_000
  end

  test "the hub is ready once every configured server registered, tools or not" do
    hub = start_hub([:first, :second])
    connect([])
    assert Hub.await_ready(100, hub) == :timeout

    connect([])
    assert Hub.await_ready(5_000, hub) == :ok
    assert Enum.sort(Catalog.registered_servers(:"#{hub}.Catalog")) == [:first, :second]
  end

  test "a hub that is not running is never ready" do
    assert Hub.await_ready(100, :no_such_hub) == :timeout
    assert Catalog.registered_servers(:no_such_catalog) == []
  end
end
