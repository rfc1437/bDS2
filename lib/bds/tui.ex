defmodule BDS.TUI do
  @moduledoc """
  Terminal UI entry point (issue #26), served per SSH connection by
  `ExRatatui.SSH.Daemon` in server mode and runnable locally.

  Placeholder shell for now: renders the app banner while the workbench
  renderer lands in a later phase. The UI locale is the server-side UI
  language setting, same as the GUI.
  """

  use ExRatatui.App
  use Gettext, backend: BDS.Gettext

  alias BDS.Desktop.UILocale
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph

  @impl true
  def mount(_opts) do
    UILocale.put(BDS.Desktop.ShellData.ui_language())
    {:ok, %{}}
  end

  @impl true
  def render(_state, frame) do
    text =
      "bDS2 — " <>
        dgettext("ui", "Blogging Desktop Server") <>
        "\n\n" <>
        dgettext("ui", "Press q to quit.")

    [{%Paragraph{text: text}, %Rect{x: 0, y: 0, width: frame.width, height: frame.height}}]
  end

  @impl true
  def handle_event(%ExRatatui.Event.Key{code: "q"}, state), do: {:stop, state}
  def handle_event(_event, state), do: {:noreply, state}
end
