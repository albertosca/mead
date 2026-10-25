defmodule Mead.ListSessionsTest do
  # Sets the global :storage setting, so it must not run beside other tests.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    previous = Application.fetch_env(:mead, :storage)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mead, :storage, value)
        :error -> Application.delete_env(:mead, :storage)
      end
    end)
  end

  test "without storage nothing is listed" do
    Application.delete_env(:mead, :storage)
    {:ok, session_id} = Mead.start_session()
    on_exit(fn -> Mead.stop_session(session_id) end)

    assert Mead.list_sessions() == {:ok, []}
  end

  test "says which stored sessions run", %{tmp_dir: directory} do
    Application.put_env(:mead, :storage, directory: directory)
    {:ok, running} = Mead.start_session()
    {:ok, stopped} = Mead.start_session()
    on_exit(fn -> Mead.stop_session(running) end)
    {:ok, _output} = Mead.submit_turn(running, "a")
    {:ok, _output} = Mead.submit_turn(stopped, "b")
    :ok = Mead.stop_session(stopped)

    assert {:ok, entries} = Mead.list_sessions()
    by_id = Map.new(entries, &{&1.session_id, &1})
    assert by_id[running].running == true
    assert by_id[stopped].running == false
    assert %DateTime{} = by_id[stopped].updated_at
  end

  test "a read failure is a persistence error", %{tmp_dir: directory} do
    path = Path.join(directory, "file")
    File.write!(path, "x")
    Application.put_env(:mead, :storage, directory: path)

    assert {:error, {:persistence, _reason}} = Mead.list_sessions()
  end
end
