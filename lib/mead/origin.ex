defmodule Mead.Origin do
  @moduledoc """
  The `Origin` rule of every HTTP surface of the runtime: protection against DNS rebinding and
  cross-site WebSocket hijacking.

  A request without an `Origin` header (a native client) passes. One with exactly one value passes
  when that value is a loopback origin or is listed in the allowed origins; anything else, several
  values included, is refused.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @spec check(Plug.Conn.t(), [String.t()]) :: :ok | :forbidden
  def check(conn, allowed_origins) do
    case get_req_header(conn, "origin") do
      [] -> :ok
      [origin] -> if allowed?(origin, allowed_origins), do: :ok, else: :forbidden
      _several -> :forbidden
    end
  end

  defp allowed?(origin, allowed_origins),
    do: origin in allowed_origins or loopback_origin?(origin)

  defp loopback_origin?(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and host in @loopback_hosts ->
        true

      _other ->
        false
    end
  end
end
