defmodule Mead.MCP.Transport do
  @moduledoc """
  Behaviour for the pipe between a `Mead.MCP.Connection` and one MCP server.

  A transport is a process started by, and linked to, its owner (the connection). It moves opaque
  binaries, one JSON message each, and knows nothing about MCP. It tells the owner what happened
  with plain messages:

    * `{:mcp_message, transport, binary}` - one complete message arrived from the server.
    * `{:mcp_closed, transport, reason}` - the pipe is gone and the transport is shutting down.
    * `{:mcp_send_failed, transport, id, reason}` - the message sent with that `id` (or `nil` for
      a notification) could not be delivered or answered at the transport level.

  A transport never raises to its owner for an expected failure. When the owner dies, the
  transport must release whatever it holds, including an operating-system process.
  """

  @callback start_link(options :: keyword(), owner :: pid()) :: GenServer.on_start()

  @callback send_message(transport :: pid(), id :: integer() | nil, message :: binary()) ::
              :ok | {:error, term()}
end
