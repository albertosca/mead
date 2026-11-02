defmodule Mead.NamedRoutesTest do
  # Sets the global :router setting, so it must not run beside other tests.
  use ExUnit.Case, async: false

  alias Mead.Ledger
  alias Mead.MCP.Server.Tools
  alias Mead.Router
  alias Mead.Test.{FakeProvider, TextHandler}

  defmodule BlockingProvider do
    @moduledoc false
    @behaviour Mead.Provider

    # Holds the turn until the test kills the server, so the turn is cut with its route recorded.
    @impl true
    def complete(_messages, options) do
      send(Keyword.fetch!(options, :test_pid), {:blocked, self()})

      receive do
        :release -> {:ok, %{text: "released", usage: %{input_tokens: 1, output_tokens: 1}}}
      after
        30_000 -> {:error, :never_released}
      end
    end
  end

  setup do
    previous = Application.fetch_env(:mead, :router)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mead, :router, value)
        :error -> Application.delete_env(:mead, :router)
      end
    end)

    :ok
  end

  defp configure_slots(slots), do: Application.put_env(:mead, :router, slots: slots)

  describe "routes/0" do
    test "is auto, local and cloud when nothing is configured" do
      Application.delete_env(:mead, :router)
      assert Router.routes() == [:auto, :local, :cloud]
    end

    test "adds the other configured slots in config order" do
      configure_slots(cloud: nil, gemma: nil, local: nil, tiny: nil)
      assert Router.routes() == [:auto, :local, :cloud, :gemma, :tiny]
    end

    test "never lists auto twice, nor a slot twice" do
      configure_slots(auto: nil, gemma: nil, gemma: nil, local: nil)
      assert Router.routes() == [:auto, :local, :cloud, :gemma]
    end

    test "never lists nil, true or false, which a recorded turn could not continue on" do
      configure_slots([{nil, nil}, {true, nil}, {false, nil}, {:gemma, nil}])
      assert Router.routes() == [:auto, :local, :cloud, :gemma]
    end

    test "ignores a config that is not a keyword list" do
      Application.put_env(:mead, :router, :broken)
      assert Router.routes() == [:auto, :local, :cloud]

      Application.put_env(:mead, :router, slots: "broken")
      assert Router.routes() == [:auto, :local, :cloud]
    end
  end

  describe "submit_turn/3" do
    setup do
      {:ok, session_id} = Mead.start_session(handler: TextHandler)
      on_exit(fn -> Mead.stop_session(session_id) end)
      %{session_id: session_id}
    end

    test "accepts a configured named slot as the route", %{session_id: session_id} do
      configure_slots(gemma: nil)
      assert {:ok, output} = Mead.submit_turn(session_id, "options", route: :gemma)
      assert output =~ "route: :gemma"
    end

    test "refuses a slot name that is not configured", %{session_id: session_id} do
      configure_slots(gemma: nil)
      assert Mead.submit_turn(session_id, "options", route: :tiny) == {:error, :invalid_route}
      assert {:ok, []} = Mead.history(session_id)
    end
  end

  describe "the MCP submit_turn tool" do
    setup do
      {:ok, session_id} = Mead.start_session(handler: TextHandler)
      on_exit(fn -> Mead.stop_session(session_id) end)
      %{session_id: session_id}
    end

    defp route_enum do
      %{"inputSchema" => %{"properties" => %{"route" => %{"enum" => names}}}} =
        Enum.find(Tools.definitions(), &(&1["name"] == "submit_turn"))

      names
    end

    defp submit(session_id, route) do
      arguments = %{"session_id" => session_id, "input" => "options", "route" => route}
      Tools.call("submit_turn", arguments, %{allow_effect: false})
    end

    test "the schema lists the routes of the current config" do
      configure_slots(gemma: nil)
      assert route_enum() == ["auto", "local", "cloud", "gemma"]

      configure_slots(tiny: nil)
      assert route_enum() == ["auto", "local", "cloud", "tiny"]
    end

    test "a configured name reaches the handler", %{session_id: session_id} do
      configure_slots(gemma: nil)

      assert {:ok, %{"isError" => false, "content" => [%{"text" => text}]}} =
               submit(session_id, "gemma")

      assert text =~ "route: :gemma"
    end

    test "an unknown name is refused with the routes, and never becomes an atom",
         %{session_id: session_id} do
      configure_slots(gemma: nil)
      name = "never_an_atom_#{System.unique_integer([:positive])}"

      assert {:error, {:invalid_params, message}} = submit(session_id, name)
      assert message =~ "auto, local, cloud, gemma"

      keyed = %{
        "session_id" => session_id,
        "input" => "options",
        "route" => name,
        "client_turn_id" => "keyed-unknown"
      }

      assert {:error, {:invalid_params, keyed_message}} =
               Tools.call("submit_turn", keyed, %{allow_effect: false})

      assert keyed_message =~ "auto, local, cloud, gemma"
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert {:ok, []} = Mead.history(session_id)
    end
  end

  describe "the ledger" do
    test "counts a turn on a named slot under that route" do
      reply = {:ok, %{text: "gemma reply", usage: FakeProvider.usage()}}
      configure_slots(local: nil, gemma: {FakeProvider, test_pid: self(), result: reply})
      {:ok, session_id} = Mead.start_session(handler: Mead.Router)
      on_exit(fn -> Mead.stop_session(session_id) end)

      assert {:ok, "gemma reply"} = Mead.submit_turn(session_id, "hello", route: :gemma)
      assert %{turns: turns} = Ledger.route_totals()[{:gemma, FakeProvider}]
      assert turns >= 1
      assert Enum.any?(Mead.usage().routes, &(&1.route == :gemma))
    end
  end

  describe "a keyed turn whose named slot is removed while it is cut" do
    setup do
      configure_slots(local: nil, gemma: {BlockingProvider, test_pid: self()})
      {:ok, session_id} = Mead.start_session(handler: Mead.Router)
      on_exit(fn -> Mead.stop_session(session_id) end)

      caller =
        Task.async(fn ->
          Mead.submit_turn(session_id, "hello", route: :gemma, client_turn_id: "named-slot-key")
        end)

      assert_receive {:blocked, _provider_process}, 10_000
      configure_slots(local: nil)
      server = Mead.Session.whereis(session_id, :server)
      Process.exit(server, :kill)

      %{session_id: session_id, caller: caller}
    end

    test "fails as unavailable on continuation, and the session lives on",
         %{session_id: session_id, caller: caller} do
      assert Task.await(caller, 20_000) == {:error, {:failed, {:slot_unavailable, :gemma}}}
      assert {:ok, [_turn]} = Mead.history(session_id)
      # Only an empty local slot is left, so the live server can only answer that no cloud exists.
      assert Mead.submit_turn(session_id, "after", route: :auto) ==
               {:error, {:failed, :cloud_unavailable}}
    end

    test "a resubmission with the same key gets the outcome, not :invalid_route",
         %{session_id: session_id, caller: caller} do
      outcome = Task.await(caller, 20_000)

      assert Mead.submit_turn(session_id, "hello",
               route: :gemma,
               client_turn_id: "named-slot-key"
             ) ==
               outcome

      arguments = %{
        "session_id" => session_id,
        "input" => "hello",
        "route" => "gemma",
        "client_turn_id" => "named-slot-key"
      }

      assert {:ok, %{"isError" => true}} =
               Tools.call("submit_turn", arguments, %{allow_effect: false})
    end

    test "a new key on the removed slot is still refused", %{
      session_id: session_id,
      caller: caller
    } do
      Task.await(caller, 20_000)

      assert Mead.submit_turn(session_id, "other", route: :gemma, client_turn_id: "fresh-key") ==
               {:error, :invalid_route}

      arguments = %{
        "session_id" => session_id,
        "input" => "other",
        "route" => "gemma",
        "client_turn_id" => "fresh-key"
      }

      assert {:error, {:invalid_params, message}} =
               Tools.call("submit_turn", arguments, %{allow_effect: false})

      assert message =~ "route must be one of auto, local, cloud"
      assert {:ok, [_only_the_first_turn]} = Mead.history(session_id)
    end
  end
end
