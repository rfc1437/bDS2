defmodule BDS.Desktop.ShellLive.ChatSurface do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.Desktop.ShellData

  def assistant_turn(prompt, socket) do
    [
      %{role: "user", content: prompt},
      %{role: "assistant", content: assistant_reply(socket)}
    ]
  end

  def assistant_project_name(nil), do: translated("Projects")
  def assistant_project_name(project), do: project.name

  def assistant_message_label("assistant"), do: translated("Assistant")
  def assistant_message_label("user"), do: translated("You")
  def assistant_message_label(_role), do: translated("Assistant")

  def assistant_message_testid(role), do: "assistant-message-#{role}"

  def update_shell_overlay(socket, updater) do
    case socket.assigns[:shell_overlay] do
      nil -> socket
      overlay -> assign(socket, :shell_overlay, updater.(overlay))
    end
  end

  defp assistant_reply(socket) do
    if socket.assigns.offline_mode do
      ShellData.translate(
        "Automatic AI actions stay gated by airplane mode.",
        %{},
        socket.assigns.page_language
      )
    else
      ShellData.translate(
        "The assistant sidebar chat surface is ready, but model execution is not connected yet.",
        %{},
        socket.assigns.page_language
      )
    end
  end

  defp translated(text), do: ShellData.translate(text, %{}, BDS.Desktop.UILocale.current())
end
