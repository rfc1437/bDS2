defmodule BDS.Desktop.MainWindow do
  @moduledoc false

  use GenServer

  alias Desktop.Window

  @window_id __MODULE__
  @persist_interval_ms 1_000
  @default_size {1280, 780}
  @default_min_size {800, 600}
  @state_file "window-state.json"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok)
  end

  def window_id, do: @window_id

  def window_options(extra_opts \\ []) do
    desktop_config = Application.get_env(:bds, :desktop, [])
    restored = restore_bounds()
    {default_width, default_height} = Keyword.get(desktop_config, :window_size, @default_size)
    {min_width, min_height} = Keyword.get(desktop_config, :window_min_size, @default_min_size)
    startup_bounds = clamp_startup_bounds(restored || %{width: default_width, height: default_height})

    base_opts = [
      app: :bds,
      id: window_id(),
      title: Keyword.get(desktop_config, :title, "Blogging Desktop Server"),
      size: {startup_bounds.width, startup_bounds.height},
      min_size: {min_width, min_height}
    ]

    Keyword.merge(base_opts, extra_opts)
  end

  def restore_bounds do
    with path when is_binary(path) <- window_state_path(),
         true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, bounds} <- normalize_bounds(decoded) do
      clamp_startup_bounds(bounds)
    else
      _ -> nil
    end
  end

  def persist_bounds(%{x: _x, y: _y, width: _width, height: _height} = bounds) do
    path = window_state_path()
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(bounds))
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    send(self(), :attach_window)
    {:ok, %{frame: nil, last_bounds: restore_bounds()}}
  end

  @impl true
  def handle_info(:attach_window, state) do
    case lookup_frame() do
      nil ->
        Process.send_after(self(), :attach_window, 200)
        {:noreply, state}

      frame ->
        apply_restored_bounds(frame)
        schedule_persist()
        {:noreply, %{state | frame: frame, last_bounds: current_bounds(frame) || state.last_bounds}}
    end
  end

  def handle_info(:persist_bounds, %{frame: frame} = state) do
    next_bounds = current_bounds(frame) || state.last_bounds

    if next_bounds && next_bounds != state.last_bounds do
      :ok = persist_bounds(next_bounds)
    end

    schedule_persist()
    {:noreply, %{state | last_bounds: next_bounds}}
  end

  @impl true
  def terminate(_reason, %{frame: frame, last_bounds: last_bounds}) do
    if bounds = current_bounds(frame) || last_bounds do
      _ = persist_bounds(bounds)
    end

    :ok
  end

  defp schedule_persist do
    Process.send_after(self(), :persist_bounds, @persist_interval_ms)
  end

  defp apply_restored_bounds(frame) do
    case restore_bounds() do
      %{x: x, y: y, width: width, height: height} ->
        with_wx_env(fn ->
          :wxWindow.setSize(frame, {width, height})
          :wxWindow.move(frame, {x, y})
        end)

      _ ->
        :ok
    end
  end

  defp lookup_frame do
    try do
      Window.frame(window_id())
    catch
      :exit, _ -> nil
    end
  end

  defp current_bounds(nil), do: nil

  defp current_bounds(frame) do
    with_wx_env(fn ->
      cond do
        not :wxWindow.isShown(frame) -> nil
        :wxTopLevelWindow.isFullScreen(frame) -> nil
        :wxTopLevelWindow.isMaximized(frame) -> nil
        true ->
          {x, y} = :wxWindow.getPosition(frame)
          {width, height} = :wxWindow.getSize(frame)
          %{x: x, y: y, width: width, height: height}
      end
    end)
  end

  defp with_wx_env(fun) do
    :wx.set_env(Desktop.Env.wx_env())
    fun.()
  end

  defp window_state_path do
    desktop_config = Application.get_env(:bds, :desktop, [])

    Keyword.get_lazy(desktop_config, :window_state_path, fn ->
      Path.join(config_dir(), @state_file)
    end)
  end

  defp config_dir do
    case :filename.basedir(:user_config, "bds") do
      path when is_list(path) -> List.to_string(path)
      path -> path
    end
  end

  defp normalize_bounds(%{"x" => x, "y" => y, "width" => width, "height" => height}) do
    normalize_bounds(%{x: x, y: y, width: width, height: height})
  end

  defp normalize_bounds(%{x: x, y: y, width: width, height: height})
       when is_integer(x) and is_integer(y) and is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    {:ok, %{x: x, y: y, width: width, height: height}}
  end

  defp normalize_bounds(_value), do: :error

  defp clamp_startup_bounds(bounds) do
    case client_area() do
      %{width: area_width, height: area_height} ->
        %{bounds | width: min(bounds.width, area_width), height: min(bounds.height, area_height)}

      nil ->
        bounds
    end
  end

  defp client_area do
    desktop_config = Application.get_env(:bds, :desktop, [])

    case Keyword.get(desktop_config, :window_client_area_override) do
      {x, y, width, height} when is_integer(x) and is_integer(y) and is_integer(width) and is_integer(height) ->
        %{x: x, y: y, width: width, height: height}

      _ ->
        read_client_area_from_wx()
    end
  end

  defp read_client_area_from_wx do
    created_wx? = wx_env_undefined?()

    try do
      if created_wx?, do: :wx.new()

      display = :wxDisplay.new()

      if :wxDisplay.isOk(display) do
        {x, y, width, height} = :wxDisplay.getClientArea(display)
        :wxDisplay.destroy(display)
        %{x: x, y: y, width: width, height: height}
      else
        :wxDisplay.destroy(display)
        nil
      end
    rescue
      _ -> nil
    after
      if created_wx?, do: :wx.destroy()
    end
  end

  defp wx_env_undefined? do
    try do
      case :wx.get_env() do
        :undefined -> true
        _ -> false
      end
    rescue
      ErlangError -> true
    end
  end
end
