defmodule Mead.DurableEndToEndTest do
  # A routed turn with an effect tool survives its session being killed outright: the session
  # comes back from its file, the steps recorded before the kill are replayed instead of asked of
  # the model again, the call that was running is reported to the model as in doubt instead of
  # being run twice, and the caller that submits again with the key gets the outcome.
  use ExUnit.Case, async: false

  import Mead.TestHelpers

  alias Mead.Session
  alias Mead.Session.Keeper
  alias Mead.Test.FakeProvider

  @moduletag :tmp_dir
  @moduletag :capture_log

  @tool %{name: "files__write_file", description: "Write", input_schema: %{"type" => "object"}}
  @in_doubt "This call was already running when the server stopped. It may or may not have taken effect; check before calling it again."

  setup %{tmp_dir: directory} do
    previous_storage = Application.fetch_env(:mead, :storage)
    Application.put_env(:mead, :storage, directory: directory)

    on_exit(fn ->
      Application.delete_env(:mead, :tool_handler)

      case previous_storage do
        {:ok, value} -> Application.put_env(:mead, :storage, value)
        :error -> Application.delete_env(:mead, :storage)
      end
    end)

    %{directory: directory}
  end

  test "a session killed while an effect tool runs finishes its turn without running it again",
       %{directory: directory} do
    tool_step = FakeProvider.tool_step([{"call-1", "files__write_file", %{"path" => "/a"}}])
    {:ok, script} = Agent.start_link(fn -> [tool_step, FakeProvider.text_step("checked")] end)
    provider = {FakeProvider, test_pid: self(), script: script}

    Application.put_env(:mead, :tool_handler, %{
      slots: [local: provider, cloud: provider],
      hub: [
        test_pid: self(),
        tools: [@tool],
        results: %{"files__write_file" => :block},
        classes: %{"files__write_file" => :effect}
      ]
    })

    {:ok, session_id} =
      Mead.start_session(handler: Mead.Test.ResumableToolHandler, turn_timeout: 30_000)

    on_exit(fn -> Mead.stop_session(session_id) end)

    submit = fn ->
      Mead.submit_turn(session_id, "write /a", tools: :effect, client_turn_id: "k")
    end

    caller = Task.async(submit)

    assert_receive {:provider_conversed, _messages, _tools}, 5_000
    assert_receive {:tool_called, "files__write_file", _arguments, _options}, 5_000
    assert_receive {:tool_blocked, _tool_process}, 5_000

    supervisor = Session.whereis(session_id, :supervisor)
    monitor = Process.monitor(supervisor)
    Process.exit(supervisor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :killed}, 2_000
    assert {:error, _reason} = Task.await(caller)

    # Whatever brings the session back first (its pool, or a keeper started again), the turn
    # continues exactly once.
    :ok = Supervisor.terminate_child(Mead.Supervisor, Keeper)
    {:ok, _keeper} = Supervisor.restart_child(Mead.Supervisor, Keeper)
    assert :ok == Keeper.recover(directory)

    assert_receive {:provider_conversed, messages, _tools}, 10_000
    assert %{role: :user, content: [%{content: @in_doubt, is_error: true}]} = List.last(messages)

    wait_until(fn -> match?({:ok, [%{status: :ok}]}, Mead.history(session_id)) end)
    assert {:ok, "checked"} = submit.()

    refute_received {:provider_conversed, _messages, _tools}
    refute_received {:tool_blocked, _tool_process}
    refute_received {:tool_called, _name, _arguments, _options}
  end
end
