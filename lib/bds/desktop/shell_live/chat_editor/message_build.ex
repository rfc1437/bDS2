defmodule BDS.Desktop.ShellLive.ChatEditor.MessageBuild do
  @moduledoc false

  alias BDS.AI
  alias BDS.AI.ChatConversation
  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.ChatEditor.{ModelSelection, ToolSurfaces, ToolTracking}

  @spec build(term()) :: term()
  def build(%{current_tab: %{type: :chat, id: conversation_id}} = assigns) do
    case AI.get_chat_conversation(conversation_id) do
      nil ->
        nil

      %ChatConversation{} = conversation ->
        messages = AI.list_chat_messages(conversation.id)
        request = Map.get(assigns.chat_editor_requests, conversation.id)
        effective_model = AI.effective_chat_model(conversation)
        available_models = AI.available_chat_models(effective_model)

        %{
          id: conversation.id,
          title: conversation.title || translated("chat.newChat"),
          model: conversation.model,
          effective_model: effective_model,
          available_models: available_models,
          available_model_groups: ModelSelection.group_available_models(available_models),
          model_selector_open?:
            Map.get(assigns.chat_model_selectors_open, conversation.id, false),
          input: Map.get(assigns.chat_editor_inputs, conversation.id, ""),
          messages: build_entries(messages, assigns),
          pending_user_message: pending_user_message(messages, request),
          is_streaming: not is_nil(request),
          streaming_content: streaming_content(request),
          streaming_tool_markers: ToolTracking.tool_markers_from_events(request),
          streaming_inline_surfaces: streaming_inline_surfaces(conversation.id, request, assigns),
          offline?: Map.get(assigns, :offline_mode, true),
          needs_api_key?: ModelSelection.needs_api_key?(Map.get(assigns, :offline_mode, true)),
          action_error: Map.get(assigns.chat_editor_action_errors, conversation.id),
          send_disabled?:
            String.trim(Map.get(assigns.chat_editor_inputs, conversation.id, "")) == "" or
              not is_nil(request)
        }
    end
  end

  def build(_assigns), do: nil

  defp build_entries(messages, assigns) do
    {entries, current_entry, _turn_index} =
      Enum.reduce(messages, {[], nil, -1}, fn message, {entries, current_entry, turn_index} ->
        case message.role do
          :tool ->
            if current_entry && current_entry.role == :assistant do
              {entries, append_tool_result(current_entry, message), turn_index}
            else
              {entries, current_entry, turn_index}
            end

          :system ->
            {entries, current_entry, turn_index}

          :user ->
            entries = finalize_entry(entries, current_entry)
            next_turn_index = turn_index + 1
            {entries, start_entry(message, next_turn_index, assigns), next_turn_index}

          :assistant ->
            next_entry = start_entry(message, turn_index, assigns)

            if tool_only_assistant_entry?(current_entry) do
              {entries, merge_tool_only_entry(current_entry, next_entry), turn_index}
            else
              entries = finalize_entry(entries, current_entry)
              {entries, next_entry, turn_index}
            end

          _other ->
            entries = finalize_entry(entries, current_entry)
            {entries, start_entry(message, turn_index, assigns), turn_index}
        end
      end)

    entries
    |> finalize_entry(current_entry)
    |> Enum.reverse()
  end

  defp finalize_entry(entries, nil), do: entries
  defp finalize_entry(entries, entry), do: [entry | entries]

  defp start_entry(message, turn_index, assigns) do
    tool_markers = ToolTracking.normalize_tool_calls(message.tool_calls)

    %{
      id: message.id,
      role: message.role,
      content: message.content || "",
      turn_index: turn_index,
      tool_markers: tool_markers,
      inline_surfaces:
        ToolSurfaces.build_render_surfaces(tool_markers, message.id, assigns)
        |> mark_surfaces_expanded(assigns),
      tool_surfaces: []
    }
  end

  defp append_tool_result(entry, message) do
    ToolTracking.mark_tool_call_completed(entry, message.tool_call_id, message.content)
  end

  defp tool_only_assistant_entry?(%{role: :assistant, content: content} = entry) do
    String.trim(content || "") == "" and
      (entry.tool_markers != [] or entry.inline_surfaces != [] or entry.tool_surfaces != [])
  end

  defp tool_only_assistant_entry?(_entry), do: false

  defp merge_tool_only_entry(tool_entry, assistant_entry) do
    %{
      assistant_entry
      | tool_markers: tool_entry.tool_markers ++ assistant_entry.tool_markers,
        inline_surfaces: tool_entry.inline_surfaces ++ assistant_entry.inline_surfaces,
        tool_surfaces: tool_entry.tool_surfaces ++ assistant_entry.tool_surfaces
    }
  end

  defp mark_surfaces_expanded([], _assigns), do: []

  defp mark_surfaces_expanded(surfaces, assigns) do
    dismissed = Map.get(assigns, :chat_editor_dismissed_surfaces, MapSet.new())

    surfaces
    |> Enum.reject(&MapSet.member?(dismissed, &1.id))
    |> Enum.map(&Map.put(&1, :expanded?, true))
  end

  defp pending_user_message(_messages, nil), do: nil

  defp pending_user_message(messages, %{message: message}) when is_binary(message) do
    case messages |> Enum.reverse() |> Enum.find(&(&1.role not in [:system, :tool])) do
      %{role: :user, content: ^message} -> nil
      _other -> message
    end
  end

  defp pending_user_message(_messages, _request), do: nil

  defp streaming_content(nil), do: ""
  defp streaming_content(%{content: content}) when is_binary(content), do: content
  defp streaming_content(_request), do: ""

  defp streaming_inline_surfaces(_conversation_id, nil, _assigns), do: []

  defp streaming_inline_surfaces(conversation_id, request, assigns) do
    request
    |> ToolTracking.tool_markers_from_events()
    |> ToolSurfaces.build_render_surfaces("streaming-#{conversation_id}", assigns)
    |> mark_surfaces_expanded(assigns)
  end

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
