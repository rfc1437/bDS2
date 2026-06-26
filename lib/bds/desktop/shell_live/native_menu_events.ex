defmodule BDS.Desktop.ShellLive.NativeMenuEvents do
  @moduledoc """
  Native- and titlebar-menu LiveView events extracted from `BDS.Desktop.ShellLive`.

  `ShellLive` routes the events listed in `events/0` here via a single delegating
  `handle_event/3`, passing its `handle_native_menu_action/2` callback so the
  menu-action dispatch logic stays owned by `ShellLive`.
  """

  alias BDS.Desktop.ShellLive.TitlebarMenu

  @events ~w(
    native_menu_action
    titlebar_menu_keydown
    toggle_titlebar_menu
    hover_titlebar_menu
    close_titlebar_menu
    titlebar_menu_action
  )

  @doc "Event names handled by this module."
  @spec events() :: [String.t()]
  def events, do: @events

  @typep socket :: Phoenix.LiveView.Socket.t()
  @typep native_action :: (socket(), String.t() -> socket())

  @spec handle(String.t(), map(), socket(), native_action()) :: {:noreply, socket()}
  def handle("native_menu_action", %{"action" => action}, socket, native_action) do
    {:noreply, native_action.(socket, action)}
  end

  def handle("titlebar_menu_keydown", %{"key" => key}, socket, native_action) do
    {:noreply, TitlebarMenu.handle_keydown(socket, key, native_action)}
  end

  def handle("toggle_titlebar_menu", %{"group" => group}, socket, _native_action) do
    {:noreply, TitlebarMenu.toggle(socket, group)}
  end

  def handle("hover_titlebar_menu", %{"group" => group}, socket, _native_action) do
    {:noreply, TitlebarMenu.hover(socket, group)}
  end

  def handle("close_titlebar_menu", _params, socket, _native_action) do
    {:noreply, TitlebarMenu.close(socket)}
  end

  def handle("titlebar_menu_action", %{"action" => action}, socket, native_action) do
    {:noreply, socket |> TitlebarMenu.close() |> native_action.(action)}
  end
end
