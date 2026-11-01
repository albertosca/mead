defmodule Mead.Session.Generation do
  @moduledoc """
  A fingerprint of the infrastructure a turn attempt runs under: the operating system process,
  the session pool, the turn supervisor, and the registry's partitions.

  Every root child before the pool restarts the pool when it restarts (the root is
  `rest_for_one`), a registry partition that crashes is replaced, and a node that stops comes
  back as another operating system process, so any of those cuts changes the fingerprint. A
  session that crashes on its own, inside the same pool, keeps it. `Mead.Session.History`
  compares the fingerprint of a continuation with the last attempt's to tell a cut the turn
  caused from one it did not.

  The fingerprint is an integer, so it can be stored; it means nothing outside the comparison.
  """

  @doc "The fingerprint of the infrastructure running now."
  @spec current() :: non_neg_integer()
  def current do
    :erlang.phash2({
      System.pid(),
      Process.whereis(Mead.Session.Pool),
      Process.whereis(Mead.TurnSupervisor),
      registry_partitions()
    })
  end

  # A registry that is restarting has no children to list; its absence is part of the print.
  defp registry_partitions do
    for {_id, partition, _type, _modules} <- Supervisor.which_children(Mead.Registry),
        do: partition
  catch
    :exit, _reason -> []
  end
end
