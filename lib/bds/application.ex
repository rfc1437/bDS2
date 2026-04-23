defmodule BDS.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BDS.Repo,
      BDS.Tasks,
      BDS.Preview,
      BDS.Publishing,
      {Task.Supervisor, name: BDS.Tasks.TaskSupervisor},
      BDS.Scripting.JobStore,
      {Task.Supervisor, name: BDS.Scripting.TaskSupervisor},
      BDS.Scripting.JobSupervisor
    ]

    opts = [strategy: :one_for_one, name: BDS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
