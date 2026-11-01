defmodule Mead.NativeTest do
  use ExUnit.Case, async: true

  alias Mead.Native

  @moduletag :tmp_dir

  if :os.type() == {:unix, :darwin} do
    test "full_fsync flushes a file and a directory", %{tmp_dir: directory} do
      path = Path.join(directory, "data")
      File.write!(path, "flushed")

      assert Native.full_fsync(path) == :ok
      assert Native.full_fsync(directory) == :ok
    end

    test "full_fsync reports a path it cannot open", %{tmp_dir: directory} do
      assert Native.full_fsync(Path.join(directory, "missing")) == {:error, :enoent}
    end

    test "full_fsync refuses a path that is not a string" do
      assert_raise ArgumentError, fn -> Native.full_fsync(~c"charlist") end
    end

    test "full_fsync refuses a path with a NUL byte", %{tmp_dir: directory} do
      assert Native.full_fsync(directory <> <<0>> <> "data") == {:error, :einval}
    end

    test "the native code is loaded" do
      assert Native.loaded?()
    end
  else
    test "the native code is not loaded off macOS" do
      refute Native.loaded?()
    end
  end
end
