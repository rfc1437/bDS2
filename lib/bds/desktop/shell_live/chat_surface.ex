defmodule BDS.Desktop.ShellLive.ChatSurface do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  use Gettext, backend: BDS.Gettext

  def assistant_turn(prompt, socket) do
    [
      %{role: "user", content: prompt},
      %{role: "assistant", content: assistant_reply(socket)}
    ]
  end

  def assistant_project_name(nil), do: dgettext("ui", "Projects")
  def assistant_project_name(project), do: project.name

  def assistant_message_label("assistant"), do: dgettext("ui", "Assistant")
  def assistant_message_label("user"), do: dgettext("ui", "You")
  def assistant_message_label(_role), do: dgettext("ui", "Assistant")

  def assistant_message_testid(role), do: "assistant-message-#{role}"

  def update_shell_overlay(socket, updater) do
    case socket.assigns[:shell_overlay] do
      nil -> socket
      overlay -> assign(socket, :shell_overlay, updater.(overlay))
    end
  end

  defp assistant_reply(socket) do
    if socket.assigns.offline_mode do
      BDS.Gettext.lgettext(socket.assigns.page_language, "ui", "Automatic AI actions stay gated by airplane mode.")
    else
      BDS.Gettext.lgettext(socket.assigns.page_language, "ui", "The assistant sidebar chat surface is ready, but model execution is not connected yet.")
    end
  end
end
