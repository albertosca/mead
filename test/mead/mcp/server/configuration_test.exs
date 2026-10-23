defmodule Mead.MCP.Server.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Mead.MCP.Server.Configuration

  @token "configuration-token-0123456789"

  describe "load/1" do
    test "no settings and no token mean the server is disabled" do
      assert Configuration.load([]) == :disabled
      assert Configuration.load(token: nil) == :disabled
      assert Configuration.load(port: 4041) == :disabled
    end

    test "a token alone gives the documented defaults" do
      assert {:ok, configuration} = Configuration.load(token: @token)

      assert configuration.port == 4040
      assert configuration.address == {127, 0, 0, 1}
      assert configuration.allow_effect == false
      assert configuration.allowed_origins == []
    end

    test "every setting can be overridden" do
      assert {:ok, configuration} =
               Configuration.load(
                 token: @token,
                 port: 0,
                 address: {10, 0, 0, 7},
                 allow_effect: true,
                 allowed_origins: ["https://deck.example"]
               )

      assert configuration.port == 0
      assert configuration.address == {10, 0, 0, 7}
      assert configuration.allow_effect == true
      assert configuration.allowed_origins == ["https://deck.example"]
    end

    test "the struct keeps a digest of the token and never the token" do
      {:ok, configuration} = Configuration.load(token: @token)

      assert configuration.token_digest == :crypto.hash(:sha256, @token)
      refute inspect(configuration, limit: :infinity) =~ @token
      refute String.contains?(:erlang.term_to_binary(configuration), @token)
    end

    test "inspecting the struct hides the digest too" do
      {:ok, configuration} = Configuration.load(token: @token)

      refute inspect(configuration) =~ "token_digest"
    end

    test "an invalid token is refused without echoing it" do
      for token <- ["", 123, :atom, false, ["a"], %{}] do
        assert {:error, message} = Configuration.load(token: token)
        assert message =~ "token must be a non-empty string"
      end
    end

    test "an invalid port is refused" do
      for port <- [-1, 65_536, "4040", 4040.0, nil] do
        assert {:error, message} = Configuration.load(token: @token, port: port)
        assert message =~ "port must be an integer from 0 to 65535"
        refute message =~ @token
      end
    end

    test "an invalid address is refused" do
      for address <- [
            {127, 0, 0},
            "127.0.0.1",
            {256, 0, 0, 1},
            {1, 2, 3, -1},
            {0, 0, 0, 0, 0, 0, 0, 1}
          ] do
        assert {:error, message} = Configuration.load(token: @token, address: address)
        assert message =~ "address must be an IPv4 tuple"
        refute message =~ @token
      end
    end

    test "allow_effect must be a boolean" do
      for value <- ["true", 1, nil] do
        assert {:error, message} = Configuration.load(token: @token, allow_effect: value)
        assert message =~ "allow_effect must be true or false"
      end
    end

    test "allowed_origins must be a list of strings" do
      for value <- ["https://a.example", [:atom], [1], nil, %{}] do
        assert {:error, message} = Configuration.load(token: @token, allowed_origins: value)
        assert message =~ "allowed_origins must be a list of strings"
        refute message =~ @token
      end
    end

    test "an unknown key is named, a misspelled token key is not mistaken for no token" do
      assert {:error, message} = Configuration.load(tokn: @token)
      assert message =~ ":tokn"
      refute message =~ @token
    end

    test "settings that are not a keyword list are refused" do
      for settings <- [%{token: @token}, "token", 42, [{"token", @token}]] do
        assert {:error, message} = Configuration.load(settings)
        assert message =~ "settings must be a keyword list"
        refute message =~ @token
      end
    end
  end

  describe "token_matches?/2" do
    setup do
      {:ok, configuration} = Configuration.load(token: @token)
      %{configuration: configuration}
    end

    test "accepts exactly the configured token", %{configuration: configuration} do
      assert Configuration.token_matches?(configuration, @token)
    end

    test "refuses a token of the same length that differs in the last byte", %{
      configuration: configuration
    } do
      almost = binary_part(@token, 0, byte_size(@token) - 1) <> "X"

      assert byte_size(almost) == byte_size(@token)
      refute Configuration.token_matches?(configuration, almost)
    end

    test "refuses shorter, longer, empty, and non-binary values", %{configuration: configuration} do
      refute Configuration.token_matches?(configuration, "short")
      refute Configuration.token_matches?(configuration, @token <> "extra")
      refute Configuration.token_matches?(configuration, "")
      refute Configuration.token_matches?(configuration, nil)
      refute Configuration.token_matches?(configuration, 123)
    end
  end
end
