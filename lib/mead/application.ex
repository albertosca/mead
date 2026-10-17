defmodule Mead.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _arguments) do
    children = [
      {Registry, keys: :unique, name: Mead.Registry},
      {Task.Supervisor, name: Mead.TurnSupervisor}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Mead.Supervisor)
  end
end
