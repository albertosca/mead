defmodule Mead.MCP.Server.TlsTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  @token "tls-test-token"

  defp self_signed(directory) do
    certfile = Path.join(directory, "cert.pem")
    keyfile = Path.join(directory, "key.pem")

    {_output, 0} =
      System.cmd(
        "openssl",
        ~w(req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -keyout #{keyfile} -out #{certfile}),
        stderr_to_stdout: true
      )

    [certfile: certfile, keyfile: keyfile]
  end

  defp start_server(settings) do
    name = :"tls_server_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Mead.MCP.Server, name: name, settings: [token: @token, port: 0] ++ settings},
        id: name
      )
    )

    {:ok, port} = Mead.MCP.Server.port(name)
    port
  end

  defp post(url) do
    Req.post(url,
      json: %{},
      retry: false,
      connect_options: [transport_opts: [verify: :verify_none]]
    )
  end

  test "with a certificate and key the listener answers over https and refuses plain http", %{
    tmp_dir: directory
  } do
    port = start_server(self_signed(directory))

    assert {:ok, %Req.Response{status: 401}} = post("https://127.0.0.1:#{port}/mcp")
    assert {:error, _reason} = post("http://127.0.0.1:#{port}/mcp")
  end

  test "without them the listener answers plain http" do
    port = start_server([])

    assert {:ok, %Req.Response{status: 401}} = post("http://127.0.0.1:#{port}/mcp")
  end
end
