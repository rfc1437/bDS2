defmodule BDS.Desktop.Shutdown do
  @moduledoc false

  alias BDS.Desktop.MainWindow
  alias Desktop.Window

  @stop_delay_ms 100

  @spec install_handlers(term()) :: :ok
  def install_handlers(frame) do
    :wx.set_env(Desktop.Env.wx_env())

    _ = :wxFrame.disconnect(frame, :close_window)

    :wxFrame.connect(frame, :close_window,
      callback: &__MODULE__.close_window/2,
      userData: self()
    )

    _ = :wxFrame.disconnect(frame, :command_menu_selected, id: Desktop.Wx.wxID_EXIT())

    :wxFrame.connect(frame, :command_menu_selected,
      id: Desktop.Wx.wxID_EXIT(),
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
  def command_menu_selected(_event, _command_event) do
    request_quit()
  end

  defp start_shutdown_task do
    Task.start(fn ->
      close_main_window()
      Process.sleep(@stop_delay_ms)
      System.stop(0)
    end)

    :ok
  end

  defp close_main_window do
    with frame when not is_nil(frame) <- main_frame() do
      :wx.set_env(Desktop.Env.wx_env())

      if :wxWindow.isShown(frame) do
        :wxWindow.hide(frame)
      end

      :wxWindow.destroy(frame)
    else
      _other -> :ok
    end
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp main_frame do
    Window.frame(MainWindow.window_id())
  catch
    :exit, _reason -> nil
  end
end
