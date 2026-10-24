# Tests tagged :live call the real API and spend money, so they run only on request:
# mix test --include live
# assert_receive waits only as long as the message takes to arrive, so a generous default costs
# nothing when it does and keeps a loaded machine from failing a test that was merely slow.
ExUnit.start(exclude: [:live], assert_receive_timeout: 5_000)
