defmodule Mead.Session.StoreDirectoryTest do
  # Changes the global :storage setting, so it must not run beside other tests.
  use ExUnit.Case, async: false

  alias Mead.Session.Store

  setup do
    previous = Application.fetch_env(:mead, :storage)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mead, :storage, value)
        :error -> Application.delete_env(:mead, :storage)
      end
    end)
  end

  test "directory/0 is nil when persistence is off" do
    Application.delete_env(:mead, :storage)

    assert Store.directory() == nil
  end

  test "directory/0 returns the configured directory" do
    Application.put_env(:mead, :storage, directory: "/var/lib/mead")

    assert Store.directory() == "/var/lib/mead"
  end

  test "directory/0 refuses a malformed setting" do
    for invalid <- [[directory: ""], [directory: 42], :on] do
      Application.put_env(:mead, :storage, invalid)

      assert_raise ArgumentError, fn -> Store.directory() end
    end
  end

  test "max_turns/0 is unlimited unless configured" do
    Application.delete_env(:mead, :storage)
    assert Store.max_turns() == nil

    Application.put_env(:mead, :storage, directory: "/var/lib/mead")
    assert Store.max_turns() == nil

    Application.put_env(:mead, :storage, directory: "/var/lib/mead", max_turns: 200)
    assert Store.max_turns() == 200

    Application.put_env(:mead, :storage, directory: "/var/lib/mead", max_turns: nil)
    assert Store.max_turns() == nil
  end

  test "max_turns/0 refuses anything but a positive integer" do
    for invalid <- [0, -1, 1.5, "100", :all] do
      Application.put_env(:mead, :storage, directory: "/var/lib/mead", max_turns: invalid)

      assert_raise ArgumentError, ~r/max_turns must be a positive integer/, fn ->
        Store.max_turns()
      end
    end
  end

  test "compact_after_bytes/0 defaults to one mebibyte" do
    Application.delete_env(:mead, :storage)
    assert Store.compact_after_bytes() == 1_048_576

    Application.put_env(:mead, :storage, directory: "/var/lib/mead")
    assert Store.compact_after_bytes() == 1_048_576
  end

  test "compact_after_bytes/0 returns the configured number" do
    Application.put_env(:mead, :storage, directory: "/var/lib/mead", compact_after_bytes: 4_096)

    assert Store.compact_after_bytes() == 4_096
  end

  test "compact_after_bytes/0 defaults when storage is explicitly nil" do
    Application.put_env(:mead, :storage, nil)

    assert Store.compact_after_bytes() == 1_048_576
  end

  test "compact_after_bytes/0 refuses anything but a positive integer" do
    for invalid <- [0, -1, 1.5, "1000", nil, :never] do
      Application.put_env(:mead, :storage,
        directory: "/var/lib/mead",
        compact_after_bytes: invalid
      )

      assert_raise ArgumentError, fn -> Store.compact_after_bytes() end
    end

    Application.put_env(:mead, :storage, :on)
    assert_raise ArgumentError, fn -> Store.compact_after_bytes() end
  end

  test "ledger_journal_max_bytes/0 defaults to one mebibyte" do
    Application.delete_env(:mead, :storage)
    assert Store.ledger_journal_max_bytes() == 1_048_576

    Application.put_env(:mead, :storage, directory: "/var/lib/mead")
    assert Store.ledger_journal_max_bytes() == 1_048_576

    Application.put_env(:mead, :storage,
      directory: "/var/lib/mead",
      ledger_journal_max_bytes: nil
    )

    assert Store.ledger_journal_max_bytes() == 1_048_576

    Application.put_env(:mead, :storage, nil)
    assert Store.ledger_journal_max_bytes() == 1_048_576
  end

  test "ledger_journal_max_bytes/0 returns the configured number" do
    Application.put_env(:mead, :storage,
      directory: "/var/lib/mead",
      ledger_journal_max_bytes: 4_096
    )

    assert Store.ledger_journal_max_bytes() == 4_096
  end

  test "ledger_journal_max_bytes/0 refuses anything but a positive integer" do
    for invalid <- [0, -1, 1.5, "1000", :never] do
      Application.put_env(:mead, :storage,
        directory: "/var/lib/mead",
        ledger_journal_max_bytes: invalid
      )

      assert_raise ArgumentError, fn -> Store.ledger_journal_max_bytes() end
    end

    Application.put_env(:mead, :storage, :on)
    assert_raise ArgumentError, fn -> Store.ledger_journal_max_bytes() end
  end
end
