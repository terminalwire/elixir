defmodule Terminalwire.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Terminalwire.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Terminalwire.Supervisor)
  end
end
