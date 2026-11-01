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
      assert Native.status() == :loaded
    end

    # A library that cannot be loaded is reported, not raised, so the module stays available and
    # the application can refuse to start with the reason.
    test "a library that cannot be loaded is reported as an error", %{tmp_dir: directory} do
      path = Path.join(directory, "mead_native.so")
      File.write!(path, "not a library")

      assert {:error, _reason} = Native.load_from(Path.rootname(path))
    end
  else
    test "the native code is not loaded off macOS" do
      refute Native.loaded?()
      assert Native.status() == :not_needed
    end
  end

  test "the application starts only when the native code it needs is there" do
    assert Mead.Application.native_ready(:loaded) == :ok
    assert Mead.Application.native_ready(:not_needed) == :ok

    assert Mead.Application.native_ready({:error, :enoent}) ==
             {:error, {:native_code_not_loaded, :enoent}}
  end
end
