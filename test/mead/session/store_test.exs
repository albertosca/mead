defmodule Mead.Session.StoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mead.Session.Store
  alias Mead.Session.Turn

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    %{directory: directory, session_id: Mead.UUID.generate()}
  end

  defp record(payload) do
    size = byte_size(payload)
    <<size::32, :erlang.crc32(<<size::32>>)::32, :erlang.crc32(payload)::32, payload::binary>>
  end

  defp encoded(event), do: record(:erlang.term_to_binary(event))

  defp file_of(directory, session_id), do: Path.join(directory, session_id <> ".log")

  defp write_raw(directory, session_id, binary),
    do: File.write!(file_of(directory, session_id), binary)

  defp flip_last_byte(binary) do
    size = byte_size(binary) - 1
    <<head::binary-size(^size), last>> = binary
    <<head::binary, Bitwise.bxor(last, 0xFF)>>
  end

  describe "append/3 and load/2" do
    test "a round trip keeps atoms, tuples and structs identical", context do
      turn =
        Turn.finish(
          Turn.start(%{"text" => "hi"}),
          :failed,
          {:failed, {:transport, :econnrefused}}
        )

      assert :ok = Store.append(context.directory, context.session_id, {:append, turn})
      assert Store.load(context.directory, context.session_id) == {:ok, [turn]}
    end

    test "events replay in order", %{directory: directory, session_id: session_id} do
      first = Turn.start("one")
      second = Turn.start("two")
      closed = Turn.finish(second, :ok, "answer")

      for event <- [{:append, first}, {:append, second}, {:replace_last, closed}, :interrupt] do
        assert :ok = Store.append(directory, session_id, event)
      end

      assert {:ok, [interrupted, ^closed]} = Store.load(directory, session_id)
      assert interrupted == Turn.interrupt(first)
      assert interrupted.status == :interrupted
    end

    # A failed turn stores its reason as output, and a freshly booted node has not seen the atoms
    # of an exception from a module it has not loaded yet; refusing them would make the
    # conversations that matter most (the ones with a failure) impossible to resume.
    test "a turn whose output holds an atom this node has never seen still loads", context do
      %{directory: directory, session_id: session_id} = context
      marker = "zzzzzzzz"
      unseen = String.pad_leading(Integer.to_string(System.unique_integer([:positive])), 8, "q")
      turn = Turn.finish(Turn.start("x"), :failed, String.to_atom(marker))
      payload = :erlang.term_to_binary({:append, turn})
      swapped = String.replace(payload, marker, unseen)

      assert swapped != payload
      assert_raise ArgumentError, fn -> :erlang.binary_to_term(swapped, [:safe]) end

      write_raw(directory, session_id, record(swapped))

      assert {:ok, [%Turn{output: output}]} = Store.load(directory, session_id)
      assert Atom.to_string(output) == unseen
    end

    test "a missing file is :not_found", %{directory: directory, session_id: session_id} do
      assert Store.load(directory, session_id) == {:error, :not_found}
    end

    test "the file is private to its owner", %{directory: directory, session_id: session_id} do
      :ok = Store.append(directory, session_id, {:append, Turn.start("secret")})

      assert File.stat!(file_of(directory, session_id)).mode |> Bitwise.band(0o777) == 0o600
    end
  end

  describe "a file cut short by a crash" do
    test "loads the complete records and warns, at every cut point", context do
      %{directory: directory, session_id: session_id} = context
      records = [encoded({:append, Turn.start("a")}), encoded({:append, Turn.start("b")})]
      full = IO.iodata_to_binary(records)
      [first_size, second_size] = Enum.map(records, &byte_size/1)
      boundaries = [first_size, first_size + second_size]

      for cut <- 0..byte_size(full) do
        write_raw(directory, session_id, binary_part(full, 0, cut))

        log =
          capture_log(fn ->
            assert {:ok, turns} = Store.load(directory, session_id)
            assert length(turns) == Enum.count(boundaries, &(&1 <= cut))
          end)

        assert log =~ session_id == cut not in [0 | boundaries]
      end
    end

    test "a last record that fails its checksum is dropped", context do
      %{directory: directory, session_id: session_id} = context
      kept = Turn.start("kept")

      write_raw(
        directory,
        session_id,
        encoded({:append, kept}) <> flip_last_byte(encoded({:append, Turn.start("lost")}))
      )

      log =
        capture_log(fn -> assert Store.load(directory, session_id) == {:ok, [kept]} end)

      assert log =~ session_id
    end
  end

  describe "a damaged file" do
    test "a checksum failure before the last record is :corrupt_history", context do
      %{directory: directory, session_id: session_id} = context

      write_raw(
        directory,
        session_id,
        encoded({:append, Turn.start("a")}) <>
          flip_last_byte(encoded({:append, Turn.start("b")})) <>
          encoded({:append, Turn.start("c")})
      )

      assert Store.load(directory, session_id) == {:error, :corrupt_history}
    end

    test "a payload that is not a term is :corrupt_history", context do
      write_raw(context.directory, context.session_id, record("not a term"))

      assert Store.load(context.directory, context.session_id) == {:error, :corrupt_history}
    end

    test "a payload that is a valid term but not an event is :corrupt_history", context do
      write_raw(context.directory, context.session_id, encoded({:something, "else"}))

      assert Store.load(context.directory, context.session_id) == {:error, :corrupt_history}
    end

    test "events that cannot be replayed are :corrupt_history", context do
      %{directory: directory, session_id: session_id} = context

      for event <- [
            {:replace_last, Turn.start("alone")},
            :bogus,
            {:append, :not_a_turn}
          ] do
        write_raw(directory, session_id, encoded(event))

        assert Store.load(directory, session_id) == {:error, :corrupt_history}
      end
    end
  end

  describe "a damaged header" do
    test "a flipped bit in the length of an early record is :corrupt_history, not a torn tail",
         context do
      %{directory: directory, session_id: session_id} = context

      for text <- ["a", "b", "c"] do
        :ok = Store.append(directory, session_id, {:append, Turn.start(text)})
      end

      <<first_byte, rest::binary>> = File.read!(file_of(directory, session_id))
      write_raw(directory, session_id, <<Bitwise.bxor(first_byte, 0x80), rest::binary>>)

      assert Store.load(directory, session_id) == {:error, :corrupt_history}
      assert Store.recover(directory, session_id) == {:error, :corrupt_history}
    end
  end

  describe "recover/2" do
    test "cuts a torn tail off the file so the next turn can be stored", context do
      %{directory: directory, session_id: session_id} = context
      kept = Turn.start("kept")
      :ok = Store.append(directory, session_id, {:append, kept})
      File.write!(file_of(directory, session_id), <<0, 0, 0>>, [:append])

      capture_log(fn -> assert Store.recover(directory, session_id) == {:ok, [kept]} end)

      next = Turn.start("next")
      assert :ok = Store.append(directory, session_id, {:append, next})
      assert Store.load(directory, session_id) == {:ok, [kept, next]}
    end

    test "a file without damage is left byte-identical", context do
      %{directory: directory, session_id: session_id} = context
      :ok = Store.append(directory, session_id, {:append, Turn.start("a")})
      written = File.read!(file_of(directory, session_id))

      assert {:ok, [_turn]} = Store.recover(directory, session_id)
      assert File.read!(file_of(directory, session_id)) == written
    end

    test "a missing file is :not_found", %{directory: directory, session_id: session_id} do
      assert Store.recover(directory, session_id) == {:error, :not_found}
    end
  end

  describe "rollback/2" do
    test "cuts the file back to the given size", context do
      %{directory: directory, session_id: session_id} = context
      :ok = Store.append(directory, session_id, {:append, Turn.start("a")})
      path = file_of(directory, session_id)
      size = File.stat!(path).size
      File.write!(path, "partial", [:append])

      assert Store.rollback(path, size) == :ok
      assert File.stat!(path).size == size
    end
  end

  describe "session ids" do
    test "anything but a lowercase UUID v4 never reaches the file system", %{directory: directory} do
      ids = [
        "../x",
        "/etc/passwd",
        "",
        String.upcase(Mead.UUID.generate()),
        Mead.UUID.generate() <> "x",
        String.duplicate("a", 10_000)
      ]

      for id <- ids do
        assert Store.append(directory, id, {:append, Turn.start("x")}) ==
                 {:error, :invalid_session_id}

        assert Store.load(directory, id) == {:error, :not_found}
        refute Store.exists?(directory, id)
        assert Store.delete(directory, id) == :ok
      end

      assert File.ls!(directory) == []
    end

    test "delete/2 is idempotent", %{directory: directory, session_id: session_id} do
      :ok = Store.append(directory, session_id, {:append, Turn.start("x")})

      assert Store.exists?(directory, session_id)
      assert Store.delete(directory, session_id) == :ok
      assert Store.delete(directory, session_id) == :ok
      refute Store.exists?(directory, session_id)
    end
  end
end
