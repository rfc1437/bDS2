defmodule BDS.Application do
  @moduledoc false

  use Application

  @compiled_env Application.compile_env(:bds, :current_env, Mix.env())

  # Children that depend on the boot mode (issue #26): desktop mode runs the
  # wx window shell, server mode runs headless behind the SSH daemon. Both
  # start the loopback HTTP endpoint and the CLI sync watcher.
  def mode_children(:server, _env) do
    [{BDS.Desktop.Server, []}, BDS.CliSync.Watcher, BDS.Server]
  end

  # Local TUI: the headless server plus a TUI on the launching terminal, so
  # a GUI (via tunnel) and the local terminal can work in parallel.
  def mode_children(:tui, env), do: mode_children(:server, env) ++ [{BDS.TUI, []}]

  def mode_children(:desktop, env), do: desktop_children(env)

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
    children =
      [
        {Phoenix.PubSub, name: BDS.PubSub},
        {BDS.Desktop.Endpoint, secret_key_base: desktop_secret_key_base()},
        BDS.Repo,
        BDS.RepoBootstrap,
        BDS.Tasks,
        BDS.AI.InFlight,
        BDS.Preview,
        BDS.Publishing,
        {Task.Supervisor, name: BDS.Tasks.TaskSupervisor},
        {Task.Supervisor, name: BDS.TCP.TaskSupervisor},
        BDS.Scripting.JobStore,
        {Task.Supervisor, name: BDS.Scripting.TaskSupervisor},
        BDS.Scripting.JobSupervisor,
        BDS.Embeddings.Index
      ] ++ embedding_children() ++ mode_children(BDS.Server.mode(), current_env())

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
      disable_auto_window_menu()

      window_opts =
        BDS.Desktop.MainWindow.window_options(
          menubar: BDS.Desktop.MenuBar,
          icon_menu: BDS.Desktop.Menu,
          url: &BDS.Desktop.url/0
        )

      [
        {Desktop.Window, window_opts},
        Supervisor.child_spec({BDS.Desktop.MainWindow, []}, id: BDS.Desktop.MainWindow.Watcher),
        {BDS.Desktop.DeepLink, []},
        {BDS.Desktop.RemoteConnection, []}
      ]
    end
  end

  # wxOSX injects an untracked "Window" menu into the menubar at install time,
  # which races elixir-desktop's async menu populate and ends up at an
  # unstable position. We disable it and ship our own :window menu group
  # (BDS.UI.MenuBar) placed between Blog and Help.
  defp disable_auto_window_menu do
    if :os.type() == {:unix, :darwin} do
      :wx.set_env(Desktop.Env.wx_env())
      :wxMenuBar.setAutoWindowMenu(false)
    end
  end

  defp desktop_automation? do
    System.get_env("BDS_DESKTOP_AUTOMATION") in ["1", "true", "TRUE"]
  end

  # The desktop endpoint binds to loopback only and its sessions do not need
  # to survive restarts, so without explicit config the signing secret is a
  # random per-boot value rather than a static one shipped in the repo.
  defp desktop_secret_key_base do
    Application.get_env(:bds, :desktop)[:secret_key_base] ||
      Base.encode64(:crypto.strong_rand_bytes(48))
  end
end
