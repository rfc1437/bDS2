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

    :wxFrame.connect(frame, :command_menu_selected,
      callback: &__MODULE__.command_menu_selected/2
    )

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

  defp start_shutdown_task do
    Task.start(fn ->
      MainWindow.persist_now()
      quit_module().quit()
    end)

    :ok
  end

  defp quit_module do
    Application.get_env(:bds, :desktop_window_quit_module, Window)
  end
end
