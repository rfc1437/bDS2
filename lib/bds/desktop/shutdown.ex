defmodule BDS.Desktop.Shutdown do
  @moduledoc false

  alias BDS.Desktop.MainWindow
  alias Desktop.Wx
  alias Desktop.Window

  require Record

  Record.defrecordp(:wx, Record.extract(:wx, from_lib: "wx/include/wx.hrl"))

  @spec install_handlers(term()) :: :ok
  def install_handlers(frame) do
    :wx.set_env(Desktop.Env.wx_env())

    _ = :wxFrame.disconnect(frame, :close_window)
    _ = :wxFrame.disconnect(frame, :command_menu_selected)

    :wxFrame.connect(frame, :close_window,
      callback: &__MODULE__.close_window/2,
      userData: self()
    )

    :wxFrame.connect(frame, :command_menu_selected, callback: &__MODULE__.command_menu_selected/2)

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  @spec request_quit() :: :ok
  def request_quit do
    case Application.get_env(:bds, :desktop_shutdown_module, __MODULE__) do
      __MODULE__ ->
        start_shutdown_task()

      module when is_atom(module) ->
        module.request_quit()
    end
  end

  @spec close_window(tuple(), term()) :: :ok
  def close_window(_event, close_event) do
    if :wxCloseEvent.canVeto(close_event) do
      :wxCloseEvent.veto(close_event)
    end

    request_quit()
  end

  @spec command_menu_selected(tuple(), term()) :: :ok
  def command_menu_selected(wx(id: id), _command_event) do
    if id == Wx.wxID_EXIT() do
      request_quit()
    end

    :ok
  end

  def command_menu_selected(_event, _command_event), do: :ok

  @doc """
  Terminate the OS process directly with SIGKILL.

  `Desktop.Window.quit/0` routes through `System.halt/1`, which calls the libc
  `exit()` and runs the wxWidgets C++ static destructors on the way out. On
  macOS that races the still-running wx event loop on the main thread and
  segfaults (`wxMenu::~wxMenu` vs `wxAppBase::ProcessIdle`). A SIGKILL is a
  kernel-level termination that skips those destructors entirely, so the app
  exits cleanly without producing a crash report.
  """
  @spec quit() :: :ok
  def quit do
    kill_heart()
    kill_beam()
    :ok
  end

  defp start_shutdown_task do
    Task.start(fn ->
      persist_safely()
      maybe_hide_window()
      Process.sleep(50)
      quit_module().quit()
    end)

    :ok
  end

  defp persist_safely do
    MainWindow.persist_now()
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  # heart, when present, would relaunch the app after we kill the BEAM, so it
  # has to be terminated first. When the app is started without heart (e.g. via
  # `mix`) there is nothing to do here.
  defp kill_heart do
    with heart when is_pid(heart) <- Process.whereis(:heart),
         {:links, links} <- Process.info(heart, :links),
         port when is_port(port) <- Enum.find(links, &is_port/1),
         {:os_pid, heart_pid} <- Port.info(port, :os_pid) do
      os_kill(heart_pid)
    else
      _ -> :ok
    end
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp kill_beam do
    os_kill(:os.getpid())
  end

  defp os_kill(os_pid) do
    os_kill_fun().(os_pid)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp os_kill_fun do
    Application.get_env(:bds, :desktop_os_kill_fun, &__MODULE__.hard_kill/1)
  end

  @doc false
  @spec hard_kill(charlist() | integer() | String.t()) :: :ok
  def hard_kill(os_pid) do
    System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  defp maybe_hide_window do
    module = window_module()

    if function_exported?(module, :hide, 1) do
      module.hide(MainWindow.window_id())
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec quit_module() :: module()
  def quit_module do
    Application.get_env(:bds, :desktop_window_quit_module, __MODULE__)
  end

  defp window_module do
    Application.get_env(:bds, :desktop_window_module, Window)
  end
end
