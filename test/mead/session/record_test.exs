defmodule Mead.Session.RecordTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Mead.Session.Record

  @moduletag :tmp_dir

  defp frame(payload) do
    size = byte_size(payload)
    <<size::32, :erlang.crc32(<<size::32>>)::32, :erlang.crc32(payload)::32, payload::binary>>
  end

  defp flip(binary, index) do
    <<before::binary-size(^index), byte, rest::binary>> = binary
    <<before::binary, bxor(byte, 255), rest::binary>>
  end

  test "records written back to back scan in order" do
    first = Record.encode(:first)
    binary = first <> Record.encode({:second, 2})

    assert Record.scan(binary) == {:ok, [:first, {:second, 2}], byte_size(binary), :clean}
    assert Record.scan(<<>>) == {:ok, [], 0, :clean}
  end

  test "a cut last record is a torn tail and the valid size stops before it" do
    first = Record.encode(:first)
    binary = first <> binary_part(Record.encode(:second), 0, 15)

    assert Record.scan(binary) == {:ok, [:first], byte_size(first), :torn}
  end

  test "an incomplete header is a torn tail" do
    first = Record.encode(:first)

    assert Record.scan(first <> <<0, 0, 0>>) == {:ok, [:first], byte_size(first), :torn}
    assert Record.scan(<<0, 0, 0>>) == {:ok, [], 0, :torn}
  end

  test "a last record that fails its payload checksum is a torn tail" do
    first = Record.encode(:first)
    second = Record.encode(:second)
    binary = first <> flip(second, byte_size(second) - 1)

    assert Record.scan(binary) == {:ok, [:first], byte_size(first), :torn}
  end

  test "a payload checksum that fails before the last record is corrupt" do
    first = Record.encode(:first)
    binary = flip(first, byte_size(first) - 1) <> Record.encode(:second)

    assert Record.scan(binary) == {:error, :corrupt}
  end

  test "a flipped bit in a length checksum is corrupt even in the last record" do
    assert Record.scan(flip(Record.encode(:only), 5)) == {:error, :corrupt}
  end

  test "a payload that is not a term is corrupt although its checksums are valid" do
    assert Record.scan(frame(<<1, 2, 3>>)) == {:error, :corrupt}
  end

  describe "file operations" do
    test "create_private makes an empty 0600 file and leaves an existing one alone", %{
      tmp_dir: directory
    } do
      path = Path.join(directory, "private")

      assert Record.create_private(path) == :ok
      assert File.read!(path) == ""
      assert (File.stat!(path).mode &&& 0o777) == 0o600

      File.write!(path, "kept")
      assert Record.create_private(path) == :ok
      assert File.read!(path) == "kept"
    end

    test "truncate cuts the file to the given size", %{tmp_dir: directory} do
      path = Path.join(directory, "cut")
      File.write!(path, "0123456789")

      assert Record.truncate(path, 4) == :ok
      assert File.read!(path) == "0123"
    end

    test "write_synced replaces the content and remove_leftover tolerates a missing file", %{
      tmp_dir: directory
    } do
      path = Path.join(directory, "synced")
      File.write!(path, "old")

      assert Record.write_synced(path, "new") == :ok
      assert File.read!(path) == "new"
      assert Record.remove_leftover(path) == :ok
      assert Record.remove_leftover(path) == :ok
      refute File.exists?(path)
    end

    test "sync_directory never fails", %{tmp_dir: directory} do
      assert Record.sync_directory(directory) == :ok
      assert Record.sync_directory(Path.join(directory, "missing")) == :ok
    end
  end
end
