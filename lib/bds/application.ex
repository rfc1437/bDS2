defmodule BDS.Application do
  @moduledoc false

  use Application

  def desktop_children(env \\ nil)

  def desktop_children(:test) do
    if desktop_automation?() do
      [{BDS.Desktop.Server, []}]
    else
      []
    end
  end

  def desktop_children(_env) do
    if Application.get_env(:bds, BDS.Application)[:desktop_adapter] == :desktop do
      [{BDS.Desktop.Server, []} | desktop_window_children()]
    else
      []
    end
  end

  @impl true
  def start(_type, _args) do
    children = [
      BDS.Repo,
      BDS.RepoBootstrap,
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

  defp desktop_window_children do
    if desktop_automation?() do
      []
    else
      window_opts =
        BDS.Desktop.MainWindow.window_options(
          menubar: BDS.Desktop.MenuBar,
          icon_menu: BDS.Desktop.Menu,
          url: &BDS.Desktop.url/0
        )

      [
        {Desktop.Window, window_opts},
        Supervisor.child_spec({BDS.Desktop.MainWindow, []}, id: BDS.Desktop.MainWindow.Watcher)
      ]
    end
  end

  defp desktop_automation? do
    System.get_env("BDS_DESKTOP_AUTOMATION") in ["1", "true", "TRUE"]
  end
end
