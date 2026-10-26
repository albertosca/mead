defmodule Mead.Gateway do
  @moduledoc """
  The single plug behind the shared Bandit listener: it hands a request to the MCP plug or to the
  deck plug by the first segment of its path.

    * `/deck` and anything under it go to the deck plug, when there is one;
    * everything else goes to the MCP plug, when there is one, so its own refusals (the JSON-RPC
      404 for a path other than `/mcp`) stay byte for byte what they were before the deck existed;
    * with no plug to answer, the reply is an empty `404`.

  Only the first segment selects a plug; the plugs do the rest of their own routing and refuse
  what they do not serve. The options are `mcp:` and `deck:`, each `nil` or `{module, options}`;
  each plug's `init/1` runs once, here.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options) do
    %{mcp: prepare(Keyword.get(options, :mcp)), deck: prepare(Keyword.get(options, :deck))}
  end

  @impl Plug
  def call(%Plug.Conn{path_info: ["deck" | _rest]} = conn, %{deck: {_module, _state} = deck}),
    do: dispatch(conn, deck)

  def call(conn, %{mcp: {_module, _state} = mcp}), do: dispatch(conn, mcp)

  def call(conn, _gateway), do: send_resp(conn, 404, "")

  defp prepare(nil), do: nil
  defp prepare({module, options}), do: {module, module.init(options)}

  defp dispatch(conn, {module, state}), do: module.call(conn, state)
end
