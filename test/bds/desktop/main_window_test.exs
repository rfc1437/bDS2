defmodule BDS.Desktop.MainWindowTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.MainWindow

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "bds-main-window-state-#{System.unique_integer([:positive])}.json"
      )

    previous = Application.get_env(:bds, :desktop, [])

    updated =
      previous
      |> Keyword.put(:window_state_path, path)
      |> Keyword.put(:window_client_area_override, {0, 33, 1470, 851})

    Application.put_env(:bds, :desktop, updated)

    on_exit(fn ->
      Application.put_env(:bds, :desktop, previous)
      File.rm(path)
    end)

    %{path: path}
  end

  test "window options use a smaller safe default and restore persisted size and position", %{
    path: path
  } do
    opts = MainWindow.window_options()

    assert opts[:size] == {1280, 780}
    assert opts[:min_size] == {800, 600}

    :ok = MainWindow.persist_bounds(%{x: 120, y: 80, width: 1260, height: 820})

    assert File.exists?(path)

    restored = MainWindow.window_options()
    assert restored[:size] == {1260, 820}
    assert MainWindow.restore_bounds() == %{x: 120, y: 80, width: 1260, height: 820}
  end

  test "window id and watcher process name do not collide" do
    assert MainWindow.window_id() == BDS.Desktop.MainWindow
    assert MainWindow.server_name() == BDS.Desktop.MainWindow.Watcher
  end

  test "window options clamp oversized startup bounds to the visible client area" do
    desktop = Application.get_env(:bds, :desktop, [])

    Application.put_env(
      :bds,
      :desktop,
      desktop
      |> Keyword.put(:window_size, {1600, 950})
      |> Keyword.put(:window_client_area_override, {0, 33, 1200, 700})
    )

    on_exit(fn ->
      Application.put_env(:bds, :desktop, desktop)
    end)

    opts = MainWindow.window_options()

    assert opts[:size] == {1200, 700}
  end

  test "terminate persists the last known bounds without querying wx during shutdown", %{
    path: path
  } do
    bounds = %{x: 33, y: 44, width: 900, height: 700}

    assert :ok = MainWindow.terminate(:shutdown, %{frame: :invalid_wx_frame, last_bounds: bounds})

    assert Jason.decode!(File.read!(path)) == %{
             "x" => 33,
             "y" => 44,
             "width" => 900,
             "height" => 700
           }
  end

  test "persist timer keeps last bounds when the wx frame is already gone", %{path: path} do
    bounds = %{x: 166, y: 57, width: 1280, height: 780}

    assert {:noreply, state} =
             MainWindow.handle_info(:persist_bounds, %{
               frame: :invalid_wx_frame,
               last_bounds: bounds
             })

    assert state.last_bounds == bounds

    refute File.exists?(path)
  end

  test "persist now is harmless when the window watcher is not running" do
    assert :ok = MainWindow.persist_now()
  end
end
