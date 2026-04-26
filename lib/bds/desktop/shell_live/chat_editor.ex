defmodule BDS.Desktop.ShellLive.ChatEditor do
  @moduledoc false

  use Phoenix.Component

  alias BDS.{AI, Repo}
  alias BDS.AI.ChatConversation
  alias BDS.Desktop.ShellData

  embed_templates "chat_editor_html/*"

  def assign_socket(socket) do
    assign(socket, :chat_editor, build(socket.assigns))
  end

  def update_input(socket, value, reload) do
    %{id: conversation_id} = socket.assigns.current_tab

    socket
    |> assign(:chat_editor_inputs, Map.put(socket.assigns.chat_editor_inputs, conversation_id, to_string(value || "")))
    |> reload.(socket.assigns.workbench)
  end

  def send_message(socket, reload, append_output) do
    %{id: conversation_id} = socket.assigns.current_tab
    message = socket.assigns.chat_editor_inputs |> Map.get(conversation_id, "") |> String.trim()

    cond do
      message == "" -> reload.(socket, socket.assigns.workbench)
      socket.assigns.offline_mode ->
        socket
        |> append_output.(translated("Chat"), translated("Automatic AI actions stay gated by airplane mode."), nil, "info")
        |> reload.(socket.assigns.workbench)

      true ->
        case AI.send_chat_message(conversation_id, message, project_id: socket.assigns.projects.active_project_id) do
          {:ok, _result} ->
            socket
            |> assign(:chat_editor_inputs, Map.put(socket.assigns.chat_editor_inputs, conversation_id, ""))
            |> reload.(socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("Chat"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  def build(%{current_tab: %{type: :chat, id: conversation_id}} = assigns) do
    case Repo.get(ChatConversation, conversation_id) do
      nil -> nil
      %ChatConversation{} = conversation ->
        %{
          id: conversation.id,
          title: conversation.title || translated("New Chat"),
          model: conversation.model,
          input: Map.get(assigns.chat_editor_inputs, conversation.id, ""),
          messages: AI.list_chat_messages(conversation.id),
          offline?: Map.get(assigns, :offline_mode, true)
        }
    end
  end

  def build(_assigns), do: nil

  def translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))
end