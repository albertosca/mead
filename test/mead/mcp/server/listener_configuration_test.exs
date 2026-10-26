defmodule Mead.MCP.Server.ListenerConfigurationTest do
  use ExUnit.Case, async: true

  alias Mead.MCP.Server.Configuration

  test "defaults need no token" do
    assert {:ok,
            %{
              port: 4040,
              address: {127, 0, 0, 1},
              allowed_origins: [],
              maximum_connections: 250,
              tls: nil
            }} = Configuration.listener([])
  end

  test "the listener settings are read whether or not a token is present" do
    expected = %{
      port: 0,
      address: {10, 0, 0, 7},
      allowed_origins: ["https://deck.example"],
      maximum_connections: 8,
      tls: nil
    }

    assert {:ok, ^expected} =
             Configuration.listener(
               port: 0,
               address: {10, 0, 0, 7},
               allowed_origins: ["https://deck.example"],
               maximum_connections: 8
             )

    assert {:ok, ^expected} =
             Configuration.listener(
               token: "t",
               port: 0,
               address: {10, 0, 0, 7},
               allowed_origins: ["https://deck.example"],
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

    assert {:error, "allowed_origins must be a list of strings"} =
             Configuration.listener(allowed_origins: [1])

    assert {:error, "settings must be a keyword list"} = Configuration.listener(%{})
    assert {:error, "unknown setting(s): [:colour]"} = Configuration.listener(colour: 1)
  end

  describe "tls" do
    test "a certificate and a key together turn it on" do
      assert {:ok, %{tls: [certfile: "cert.pem", keyfile: "key.pem"]}} =
               Configuration.listener(certfile: "cert.pem", keyfile: "key.pem")
    end

    test "one without the other is refused" do
      for settings <- [[certfile: "cert.pem"], [keyfile: "key.pem"]] do
        assert {:error, "certfile and keyfile must be set together"} =
                 Configuration.listener(settings)
      end
    end

    test "empty or non-string paths are refused" do
      for settings <- [
            [certfile: "", keyfile: "key.pem"],
            [certfile: "cert.pem", keyfile: ""],
            [certfile: 1, keyfile: "key.pem"],
            [certfile: "cert.pem", keyfile: :key]
          ] do
        assert {:error, "certfile and keyfile must be non-empty paths"} =
                 Configuration.listener(settings)
      end
    end
  end
end
