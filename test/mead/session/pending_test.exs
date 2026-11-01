defmodule Mead.Session.PendingTest do
  use ExUnit.Case, async: true

  alias Mead.Session.Pending

  @moduletag :tmp_dir

  @settings %{handler: Mead.Session.EchoHandler, turn_timeout: 1_000}

  test "a marked session is listed with its settings until it is cleared", %{tmp_dir: directory} do
    session_id = Mead.UUID.generate()

    assert Pending.mark(directory, session_id, @settings) == :ok
    assert Pending.list(directory) == [{session_id, @settings}]

    assert Pending.clear(directory, session_id) == :ok
    assert Pending.list(directory) == []
    assert Pending.clear(directory, session_id) == :ok
  end

  # The removal is a change to the folder, so a power cut right after a cleared marker would
  # otherwise bring it back, and the keeper would resume a turn that had already ended.
  test "clearing a marker syncs the folder it was in", %{tmp_dir: directory} do
    session_id = Mead.UUID.generate()
    :ok = Pending.mark(directory, session_id, @settings)
    folder = directory |> Path.join("pending") |> Path.expand()

    # A process does not receive its own traces, so another one forwards them.
    test_process = self()
    tracer = spawn_link(fn -> forward_traces(test_process) end)
    :erlang.trace_pattern({Mead.Session.Record, :sync_directory, 1}, true, [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      assert Pending.clear(directory, session_id) == :ok
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Mead.Session.Record, :sync_directory, 1}, false, [])
    end

    synced =
      for {:trace, _pid, :call, {Mead.Session.Record, :sync_directory, [path]}} <- flush_traces(),
          do: Path.expand(path)

    assert folder in synced
  end

  defp forward_traces(receiver) do
    receive do
      trace ->
        send(receiver, trace)
        forward_traces(receiver)
    end
  end

  defp flush_traces(collected \\ []) do
    receive do
      {:trace, _pid, :call, _call} = trace -> flush_traces([trace | collected])
    after
      200 -> Enum.reverse(collected)
    end
  end

  test "marking twice keeps one marker with the newest settings", %{tmp_dir: directory} do
    session_id = Mead.UUID.generate()
    :ok = Pending.mark(directory, session_id, @settings)
    :ok = Pending.mark(directory, session_id, %{@settings | turn_timeout: 2_000})

    assert Pending.list(directory) == [{session_id, %{@settings | turn_timeout: 2_000}}]
  end

  test "files that are not markers are ignored", %{tmp_dir: directory} do
    pending = Path.join(directory, "pending")
    File.mkdir_p!(pending)
    File.write!(Path.join(pending, "not-a-session-id"), :erlang.term_to_binary(@settings))
    File.write!(Path.join(pending, Mead.UUID.generate()), "garbage")
    File.write!(Path.join(pending, Mead.UUID.generate()), :erlang.term_to_binary(:not_a_map))

    assert Pending.list(directory) == []
  end

  test "a directory with no markers yet lists nothing", %{tmp_dir: directory} do
    assert Pending.list(Path.join(directory, "missing")) == []
  end

  test "without storage nothing is marked" do
    assert Pending.mark(nil, Mead.UUID.generate(), @settings) == :ok
    assert Pending.clear(nil, Mead.UUID.generate()) == :ok
    assert Pending.list(nil) == []
  end

  test "an id that is not a session id is refused", %{tmp_dir: directory} do
    assert Pending.mark(directory, "../escape", @settings) == {:error, :invalid_session_id}
    assert Pending.clear(directory, "../escape") == :ok
  end
end
