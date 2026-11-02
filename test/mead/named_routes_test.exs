defmodule Mead.NamedRoutesTest do
  # Sets the global :router setting, so it must not run beside other tests.
  use ExUnit.Case, async: false

  alias Mead.MCP.Server.Tools
  alias Mead.Router
  alias Mead.Test.TextHandler

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
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert {:ok, []} = Mead.history(session_id)
    end
  end
end
