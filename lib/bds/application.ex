defmodule BDS.Application do
  @moduledoc false

  use Application

  def desktop_children(env \\ nil)

  def desktop_children(:test), do: []

  def desktop_children(_env) do
    if Application.get_env(:bds, BDS.Application)[:desktop_adapter] == :desktop do
      [
        {BDS.Desktop.Server, []},
        {Desktop.Window,
         [
           app: :bds,
           id: BDS.Desktop.MainWindow,
           title: Application.get_env(:bds, :desktop)[:title] || "Blogging Desktop Server",
           size: Application.get_env(:bds, :desktop)[:window_size] || {1440, 900},
           min_size: Application.get_env(:bds, :desktop)[:window_min_size] || {1100, 700},
           menubar: BDS.Desktop.MenuBar,
           icon_menu: BDS.Desktop.Menu,
           url: &BDS.Desktop.url/0
         ]}
      ]
    else
      []
    end
  end

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
      | desktop_children(current_env())
    ]

    opts = [strategy: :one_for_one, name: BDS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp current_env do
    Application.get_env(:bds, :current_env_override) ||
      if(Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod)
  end
end
