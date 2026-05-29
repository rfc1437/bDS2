defmodule BDS.Application do
  @moduledoc false

  use Application

  @compiled_env Application.compile_env(:bds, :current_env, Mix.env())

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
      [{BDS.Desktop.Server, []}, BDS.CliSync.Watcher | desktop_window_children()]
    else
      []
    end
  end

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: BDS.PubSub},
      {BDS.Desktop.Endpoint, secret_key_base: desktop_secret_key_base()},
      BDS.Repo,
      BDS.RepoBootstrap,
      BDS.Tasks,
      BDS.Preview,
      BDS.Publishing,
      {Task.Supervisor, name: BDS.Tasks.TaskSupervisor},
      {Task.Supervisor, name: BDS.TCP.TaskSupervisor},
      BDS.Scripting.JobStore,
      {Task.Supervisor, name: BDS.Scripting.TaskSupervisor},
      BDS.Scripting.JobSupervisor,
      BDS.Embeddings.Index
    ] ++ embedding_children() ++ desktop_children(current_env())

    opts = [strategy: :one_for_one, name: BDS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The neural embedding backend runs as a supervised, lazily-initialised
  # GenServer (it loads the model only on the first embedding request). Only
  # start it when it is the configured backend.
  defp embedding_children do
    case Application.get_env(:bds, :embeddings, [])[:backend] do
      BDS.Embeddings.Backends.Neural -> [BDS.Embeddings.Backends.Neural]
      _other -> []
    end
  end

  defp current_env do
    Application.get_env(:bds, :current_env_override) || @compiled_env
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

  defp desktop_secret_key_base do
    Application.get_env(:bds, :desktop)[:secret_key_base] ||
      raise "missing :desktop secret_key_base configuration"
  end
end
