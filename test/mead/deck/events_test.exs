defmodule Mead.Deck.EventsTest do
  use ExUnit.Case, async: true

  alias Mead.Deck.Events

  defp frame(type, payload), do: JSON.encode!(%{"type" => type, "payload" => payload})

  describe "decode_client/1 valid messages" do
    test "prompt.send" do
      assert {:ok, {:prompt_send, %{client_message_id: "m-1", text: "hello"}}} =
               Events.decode_client(
                 frame("prompt.send", %{"client_message_id" => "m-1", "text" => "hello"})
               )
    end

    test "permission.respond and choice.respond" do
      payload = %{"request_id" => "r-1", "option_id" => "allow_once"}

      assert {:ok, {:permission_respond, %{request_id: "r-1", option_id: "allow_once"}}} =
               Events.decode_client(frame("permission.respond", payload))

      assert {:ok, {:choice_respond, %{request_id: "r-1", option_id: "allow_once"}}} =
               Events.decode_client(frame("choice.respond", payload))
    end

    test "tool_call.cancel" do
      assert {:ok, {:tool_call_cancel, %{tool_call_id: "t-1"}}} =
               Events.decode_client(frame("tool_call.cancel", %{"tool_call_id" => "t-1"}))
    end

    test "session.resume accepts zero and positive integers" do
      assert {:ok, {:session_resume, %{last_sequence: 0}}} =
               Events.decode_client(frame("session.resume", %{"last_sequence" => 0}))

      assert {:ok, {:session_resume, %{last_sequence: 42}}} =
               Events.decode_client(frame("session.resume", %{"last_sequence" => 42}))
    end

    test "policy.set maps every level and nothing else" do
      for {wire, level} <- [
            {"ask_always", :ask_always},
            {"ask_for_risky", :ask_for_risky},
            {"allow_all", :allow_all}
          ] do
        assert {:ok, {:policy_set, %{level: ^level}}} =
                 Events.decode_client(frame("policy.set", %{"level" => wire}))
      end
    end

    test "unknown extra fields are ignored for forward compatibility" do
      assert {:ok, {:prompt_send, %{client_message_id: "m", text: "t"}}} =
               Events.decode_client(
                 JSON.encode!(%{
                   "type" => "prompt.send",
                   "future" => true,
                   "payload" => %{"client_message_id" => "m", "text" => "t", "attachments" => []}
                 })
               )
    end
  end

  describe "decode_client/1 invalid input" do
    test "invalid payloads are reported, never raised" do
      cases = [
        {"prompt.send", %{}},
        {"prompt.send", %{"client_message_id" => "m"}},
        {"prompt.send", %{"client_message_id" => "m", "text" => ""}},
        {"prompt.send", %{"client_message_id" => "m", "text" => "  \n\t "}},
        {"prompt.send", %{"client_message_id" => "m", "text" => 5}},
        {"prompt.send", %{"client_message_id" => "", "text" => "hi"}},
        {"prompt.send", %{"client_message_id" => String.duplicate("a", 129), "text" => "hi"}},
        {"prompt.send", %{"client_message_id" => 7, "text" => "hi"}},
        {"permission.respond", %{"request_id" => "r"}},
        {"permission.respond", %{"option_id" => "o"}},
        {"choice.respond", %{"request_id" => "", "option_id" => "o"}},
        {"tool_call.cancel", %{}},
        {"tool_call.cancel", %{"tool_call_id" => 3}},
        {"session.resume", %{}},
        {"session.resume", %{"last_sequence" => -1}},
        {"session.resume", %{"last_sequence" => 1.5}},
        {"session.resume", %{"last_sequence" => "3"}},
        {"policy.set", %{"level" => "allow_everything"}},
        {"policy.set", %{"level" => nil}},
        {"policy.set", %{}}
      ]

      for {type, payload} <- cases do
        assert {:error, :invalid_payload} = Events.decode_client(frame(type, payload)),
               "expected #{type} #{inspect(payload)} to be refused"
      end
    end

    test "a payload that is not an object is invalid" do
      for payload <- [nil, [], "x", 3] do
        assert {:error, :invalid_payload} = Events.decode_client(frame("prompt.send", payload))
      end

      assert {:error, :invalid_payload} =
               Events.decode_client(JSON.encode!(%{"type" => "prompt.send"}))
    end

    test "unknown or malformed types" do
      assert {:error, :unknown_type} = Events.decode_client(frame("nope", %{}))
      assert {:error, :unknown_type} = Events.decode_client(JSON.encode!(%{"payload" => %{}}))
      assert {:error, :unknown_type} = Events.decode_client(frame(5, %{}))
      assert {:error, :unknown_type} = Events.decode_client(frame("heartbeat", %{}))
    end

    test "frames that are not JSON objects" do
      assert {:error, :not_json} = Events.decode_client("")
      assert {:error, :not_json} = Events.decode_client("{\"type\":")
      assert {:error, :not_json} = Events.decode_client("hello")
      assert {:error, :not_json} = Events.decode_client(<<"{\"type\":\"", 255, "\"}">>)
      assert {:error, :not_object} = Events.decode_client("[]")
      assert {:error, :not_object} = Events.decode_client("\"x\"")
      assert {:error, :not_object} = Events.decode_client("null")
      assert {:error, :not_object} = Events.decode_client("3")
    end

    test "the size limit is exact" do
      assert Events.maximum_frame_bytes() == 65_536

      overhead = byte_size(frame("prompt.send", %{"client_message_id" => "m", "text" => ""}))
      exact = String.duplicate("a", 65_536 - overhead)

      assert byte_size(frame("prompt.send", %{"client_message_id" => "m", "text" => exact})) ==
               65_536

      assert {:ok, {:prompt_send, _}} =
               Events.decode_client(
                 frame("prompt.send", %{"client_message_id" => "m", "text" => exact})
               )

      assert {:error, :too_large} =
               Events.decode_client(
                 frame("prompt.send", %{"client_message_id" => "m", "text" => exact <> "a"})
               )
    end

    test "non-binary input is refused without raising" do
      assert {:error, :not_json} = Events.decode_client(nil)
      assert {:error, :not_json} = Events.decode_client(%{})
    end
  end

  describe "envelope/5 and encode/1" do
    test "carries the five fields with an ISO 8601 UTC timestamp" do
      occurred_at = ~U[2026-10-26 12:00:00.123456Z]
      envelope = Events.envelope(7, "session-1", "text.delta", %{"text" => "x"}, occurred_at)

      assert envelope == %{
               "sequence" => 7,
               "session_id" => "session-1",
               "type" => "text.delta",
               "occurred_at" => "2026-10-26T12:00:00.123456Z",
               "payload" => %{"text" => "x"}
             }
    end

    test "unsequenced events carry a null sequence" do
      envelope = Events.envelope(nil, "s", "heartbeat", %{}, ~U[2026-10-26 12:00:00Z])
      assert envelope["sequence"] == nil
      assert Events.encode(envelope) =~ ~s("sequence":null)
    end

    test "encode round-trips through JSON" do
      envelope =
        Events.envelope(1, "s", "prompt.accepted", %{"text" => "olá ✓"}, ~U[2026-10-26 12:00:00Z])

      assert envelope |> Events.encode() |> JSON.decode!() == envelope
    end
  end

  describe "the server event vocabulary" do
    test "is pinned to the deck contract" do
      assert Events.server_event_types() ==
               ~w(session.snapshot prompt.accepted text.delta tool_call.updated permission.requested permission.resolved choice.requested choice.resolved metric.updated policy.updated heartbeat)
    end

    test "policy level names round trip" do
      for level <- [:ask_always, :ask_for_risky, :allow_all] do
        assert {:ok, ^level} = level |> Events.policy_level_name() |> Events.parse_policy_level()
      end

      assert Events.parse_policy_level("bogus") == :error
      assert Events.parse_policy_level(nil) == :error
    end
  end
end
