defmodule BDS.Desktop.Menu do
  @moduledoc false

  use Desktop.Menu
  alias Desktop.Window

  @impl true
  def mount(menu) do
    {:ok, menu}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <menu>
      <item onclick="open">Open</item>
      <hr />
      <item onclick="quit">Quit</item>
    </menu>
    """
  end

  @impl true
  def handle_event("open", menu) do
    Window.show(BDS.Desktop.MainWindow.window_id())
    {:noreply, menu}
  end

  def handle_event("quit", menu) do
    Window.quit()
    {:noreply, menu}
  end

  def handle_event(_, menu) do
    {:noreply, menu}
  end

  @impl true
  def handle_info(_, menu) do
    {:noreply, menu}
  end
end
