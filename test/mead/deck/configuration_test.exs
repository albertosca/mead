defmodule Mead.Deck.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Mead.Deck.Configuration

  @token "deck-configuration-token-0123456789"

  describe "load/1" do
    test "no settings and no token mean the deck is disabled" do
      assert Configuration.load([]) == :disabled
      assert Configuration.load(token: nil) == :disabled
      assert Configuration.load(queue_limit: 3) == :disabled
    end

    test "a token alone gives the documented defaults" do
      assert {:ok, configuration} = Configuration.load(token: @token)

      assert configuration.ticket_ttl_ms == 10_000
      assert configuration.permission_timeout_ms == 120_000
      assert configuration.heartbeat_ms == 15_000
      assert configuration.resume_deadline_ms == 10_000
      assert configuration.queue_limit == 10
      assert configuration.default_policy_level == :ask_for_risky
    end

    test "every setting can be overridden" do
      assert {:ok, configuration} =
               Configuration.load(
                 token: @token,
                 ticket_ttl_ms: 20,
                 permission_timeout_ms: 30,
                 heartbeat_ms: 40,
                 resume_deadline_ms: 50,
                 queue_limit: 2,
                 default_policy_level: :ask_always
               )

      assert configuration.ticket_ttl_ms == 20
      assert configuration.permission_timeout_ms == 30
      assert configuration.heartbeat_ms == 40
      assert configuration.resume_deadline_ms == 50
      assert configuration.queue_limit == 2
      assert configuration.default_policy_level == :ask_always
    end

    test "every positive-integer setting refuses zero, negatives, floats and strings" do
      for setting <- [
            :ticket_ttl_ms,
            :permission_timeout_ms,
            :heartbeat_ms,
            :resume_deadline_ms,
            :queue_limit,
            :event_log_limit
          ],
          value <- [0, -1, 1.5, "10", nil, :infinity] do
        assert {:error, message} = Configuration.load([{:token, @token}, {setting, value}])
        assert message =~ "#{setting} must be a positive integer"
        refute message =~ @token
      end
    end

    test "a heartbeat slower than 30 seconds is refused" do
      assert {:ok, _} = Configuration.load(token: @token, heartbeat_ms: 30_000)
      assert {:error, message} = Configuration.load(token: @token, heartbeat_ms: 30_001)
      assert message =~ "heartbeat_ms must be at most 30000"
    end

    test "an unknown policy level is refused" do
      for value <- [:allow_everything, "allow_all", nil, 1] do
        assert {:error, message} = Configuration.load(token: @token, default_policy_level: value)
        assert message =~ "default_policy_level must be one of"
      end
    end

    test "an empty or non-string token is refused without echoing it" do
      for value <- ["", 123, :atom, ["secret"]] do
        assert {:error, message} = Configuration.load(token: value)
        assert message =~ "token must be a non-empty string"
        refute message =~ "secret"
      end
    end

    test "unknown settings and non-keyword settings are refused" do
      assert {:error, message} = Configuration.load(token: @token, colour: :red)
      assert message =~ "unknown setting(s)"
      refute message =~ @token

      assert {:error, "settings must be a keyword list"} = Configuration.load(%{token: @token})
      assert {:error, "settings must be a keyword list"} = Configuration.load("token")
    end

    test "the struct keeps a digest of the token and inspect hides everything secret" do
      {:ok, configuration} = Configuration.load(token: @token)

      assert configuration.token_digest == :crypto.hash(:sha256, @token)
      refute inspect(configuration, limit: :infinity) =~ @token
      refute inspect(configuration, limit: :infinity) =~ "token_digest"
      refute String.contains?(:erlang.term_to_binary(configuration), @token)
    end
  end

  describe "token_matches?/2" do
    setup do
      {:ok, configuration} = Configuration.load(token: @token)
      %{configuration: configuration}
    end

    test "accepts the token only", %{configuration: configuration} do
      assert Configuration.token_matches?(configuration, @token)
      refute Configuration.token_matches?(configuration, @token <> "x")
      refute Configuration.token_matches?(configuration, "")
      refute Configuration.token_matches?(configuration, nil)
      refute Configuration.token_matches?(configuration, 123)
    end
  end
end
