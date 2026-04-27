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

  def toggle_model_selector(socket, reload) do
    %{id: conversation_id} = socket.assigns.current_tab
    current = Map.get(socket.assigns.chat_model_selectors_open, conversation_id, false)

    socket
    |> assign(:chat_model_selectors_open, Map.put(socket.assigns.chat_model_selectors_open, conversation_id, not current))
    |> reload.(socket.assigns.workbench)
  end

  def set_model(socket, model_id, reload, append_output) do
    %{id: conversation_id} = socket.assigns.current_tab

    case AI.set_conversation_model(conversation_id, model_id) do
      {:ok, _conversation} ->
        socket
        |> assign(:chat_model_selectors_open, Map.put(socket.assigns.chat_model_selectors_open, conversation_id, false))
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Chat"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
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
          title: conversation.title || translated("chat.newChat"),
          model: conversation.model,
          available_models: AI.available_chat_models(conversation.model),
          model_selector_open?: Map.get(assigns.chat_model_selectors_open, conversation.id, false),
          input: Map.get(assigns.chat_editor_inputs, conversation.id, ""),
          messages: build_entries(AI.list_chat_messages(conversation.id)),
          offline?: Map.get(assigns, :offline_mode, true)
        }
    end
  end

  def build(_assigns), do: nil

  def message_role_label(:user), do: translated("chat.role.you")
  def message_role_label(_role), do: translated("chat.role.assistant")

  def tool_call_name(tool_call) when is_map(tool_call) do
    Map.get(tool_call, "name") || Map.get(tool_call, :name) || "tool"
  end

  def tool_surface_type(surface), do: Map.get(surface, :type, "json")

  defp build_entries(messages) do
    {entries, current_entry} =
      Enum.reduce(messages, {[], nil}, fn message, {entries, current_entry} ->
        case message.role do
          :tool ->
            if current_entry && current_entry.role == :assistant do
              {entries, append_tool_surface(current_entry, message)}
            else
              {entries, current_entry}
            end

          :system ->
            {entries, current_entry}

          _other ->
            entries = finalize_entry(entries, current_entry)
            {entries, start_entry(message)}
        end
      end)

    entries
    |> finalize_entry(current_entry)
    |> Enum.reverse()
  end

  defp finalize_entry(entries, nil), do: entries
  defp finalize_entry(entries, entry), do: [entry | entries]

  defp start_entry(message) do
    %{
      id: message.id,
      role: message.role,
      content: message.content || "",
      tool_markers: normalize_tool_calls(message.tool_calls),
      tool_surfaces: []
    }
  end

  defp append_tool_surface(entry, message) do
    case normalize_tool_surface(message.content) do
      nil -> entry
      surface -> update_in(entry.tool_surfaces, &(&1 ++ [surface]))
    end
  end

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      %{
        name: tool_call_name(tool_call),
        arguments: Map.get(tool_call, "arguments") || Map.get(tool_call, :arguments) || Map.get(tool_call, "args") || Map.get(tool_call, :args) || %{}
      }
    end)
  end

  defp normalize_tool_calls(_tool_calls), do: []

  defp normalize_tool_surface(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"type" => type} = decoded} ->
        %{
          type: type,
          title: decoded["title"],
          columns: List.wrap(decoded["columns"]),
          rows: Enum.map(List.wrap(decoded["rows"]), &List.wrap/1),
          fields: List.wrap(decoded["fields"]),
          data: decoded
        }

      _other ->
        nil
    end
  end

  defp normalize_tool_surface(_content), do: nil

  def translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))
end
