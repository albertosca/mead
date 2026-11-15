defmodule Mead.MCP.HubCredentialsTest.RecordingTransport do
  @moduledoc false

  # Reports the options it was started with, so a test can tell that the credentials a hub hides
  # from its reports still reach the transport.

  @behaviour Mead.MCP.Transport

  @impl Mead.MCP.Transport
  def start_link(options, _owner) do
    send(Keyword.fetch!(options, :test_pid), {:started_with, options})
    Agent.start_link(fn -> :ok end)
  end

  @impl Mead.MCP.Transport
  def send_message(_transport, _id, _message), do: :ok
end

defmodule Mead.MCP.HubCredentialsTest do
  # The hub reads its servers from the application environment, as it does in production, so this
  # module cannot run beside others that read or write the same key.
  use ExUnit.Case, async: false

  alias Mead.MCP.Hub
  alias Mead.MCP.HubCredentialsTest.RecordingTransport

  @moduletag :capture_log

  @environment_secret "SECRET-ENVIRONMENT-0123456789"
  @header_secret "Bearer SECRET-HEADER-0123456789"

  setup do
    previous = Application.fetch_env(:mead, :mcp)

    Application.put_env(:mead, :mcp,
      servers: [
        bridge: [
          transport: {:stdio, command: "unused", env: [{"BRIDGE_TOKEN", @environment_secret}]},
          tools: [status: :read]
        ],
        remote: [
          transport:
            {:http, url: "https://example.test/mcp", headers: [{"authorization", @header_secret}]},
          tools: [search: :read]
        ]
      ]
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mead, :mcp, value)
        :error -> Application.delete_env(:mead, :mcp)
      end
    end)

    name = :"credentials_hub_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Hub,
       name: name,
       transports: %{
         stdio: {RecordingTransport, [test_pid: self()]},
         http: {RecordingTransport, [test_pid: self()]}
       },
       reconnect_delays: [10],
       handshake_timeout: 60_000}
    )

    %{hub: name}
  end

  # What a supervisor report or `:sys.get_status/1` would print for the hub and each of its
  # children, with no limit, since a credential printed past a truncation still counts as printed.
  defp everything_printed(hub) do
    children =
      for {_id, pid, _type, _modules} <- Supervisor.which_children(hub), is_pid(pid), do: pid

    [hub | children]
    |> Enum.map_join(
      "\n",
      &inspect(:sys.get_status(&1), limit: :infinity, printable_limit: :infinity)
    )
  end

  test "the transports still start with the credentials the configuration holds", %{hub: _hub} do
    assert_receive {:started_with, stdio_options}, 10_000
    assert_receive {:started_with, http_options}, 10_000

    options = [stdio_options, http_options]

    assert Enum.any?(options, &(&1[:env] == [{"BRIDGE_TOKEN", @environment_secret}]))
    assert Enum.any?(options, &(&1[:headers] == [{"authorization", @header_secret}]))
  end

  test "no credential of a transport appears in what the hub and its children print", %{hub: hub} do
    # Both connections have started their transports, so every child of the hub is in place.
    assert_receive {:started_with, _first}, 10_000
    assert_receive {:started_with, _second}, 10_000

    printed = everything_printed(hub)

    refute printed =~ @environment_secret
    refute printed =~ @header_secret
  end
end
