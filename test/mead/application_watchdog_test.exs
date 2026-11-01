defmodule Mead.ApplicationWatchdogTest do
  # Takes the whole root supervisor down, so it must not overlap with any other test.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  alias Mead.Session.Turn
  alias Mead.Test.ResumableHandler

  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag timeout: 30_000

  setup %{tmp_dir: directory} do
    previous_storage = Application.fetch_env(:mead, :storage)
    Application.put_env(:mead, :storage, directory: directory)

    on_exit(fn ->
      case previous_storage do
        {:ok, value} -> Application.put_env(:mead, :storage, value)
        :error -> Application.delete_env(:mead, :storage)
      end
    end)

    :ok
  end

  test "the application's top process is the watchdog, and it holds the root supervisor" do
    {top, Mead.Application} =
      :application_controller.get_master(:mead) |> :application_master.get_child()

    assert top == Process.whereis(Mead.Watchdog)
    assert Mead.Watchdog.child(Mead.Watchdog) == Process.whereis(Mead.Supervisor)
  end

  # Past 10 restarts in 5 seconds the root supervisor gives up, which used to stop the
  # application; the watchdog starts it again and the keeper continues the turn it cut.
  test "a root supervisor that runs out of restarts comes back and the running turn continues" do
    {:ok, session_id} = Mead.start_session(handler: ResumableHandler, turn_timeout: 30_000)
    on_exit(fn -> Mead.stop_session(session_id) end)
    input = {:checkpointed, self(), [:a, :b]}
    caller = Task.async(fn -> Mead.submit_turn(session_id, input) end)
    assert_receive {:handler_at, _pid, [:a]}

    root = Process.whereis(Mead.Supervisor)
    reference = Process.monitor(root)
    exhaust_root_restarts(root)
    assert_receive {:DOWN, ^reference, :process, ^root, _reason}, 5_000

    new_root =
      wait_until(
        fn ->
          candidate = Process.whereis(Mead.Supervisor)
          is_pid(candidate) and candidate != root and candidate
        end,
        10_000
      )

    assert Process.alive?(new_root)
    assert_receive {:resumed_with, [:a]}, 10_000
    assert_receive {:handler_at, handler_pid, [:a, :b]}, 10_000
    send(handler_pid, :release)

    assert Task.await(caller, 15_000) == {:ok, [:a, :b]}
    assert {:ok, [%Turn{status: :ok, output: [:a, :b]}]} = Mead.history(session_id)
  end

  # Kills the deck tickets, a late child, until the root stops restarting it.
  defp exhaust_root_restarts(root) do
    if Process.alive?(root) do
      case Process.whereis(Mead.Deck.Tickets) do
        tickets when is_pid(tickets) ->
          Process.exit(tickets, :kill)

          wait_until(fn ->
            not Process.alive?(root) or
              Process.whereis(Mead.Deck.Tickets) not in [nil, tickets]
          end)

        nil ->
          Process.sleep(5)
      end

      exhaust_root_restarts(root)
    end
  end
end
