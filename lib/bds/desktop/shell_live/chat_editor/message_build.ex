defmodule BDS.Desktop.ShellLive.ChatEditor.MessageBuild do
  @moduledoc false

  alias BDS.AI
  alias BDS.AI.ChatConversation
  alias BDS.Desktop.ShellLive.ChatEditor.{ModelSelection, ToolSurfaces, ToolTracking}
  use Gettext, backend: BDS.Gettext

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
        streaming_tool_markers = streaming_tool_markers(messages, request)
        streaming_content = streaming_content(messages, request)

        %{
          id: conversation.id,
          title: conversation.title || dgettext("ui", "New Chat"),
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
          streaming_content: streaming_content,
          streaming_tool_markers: streaming_tool_markers,
          streaming_inline_surfaces:
            streaming_inline_surfaces(conversation.id, streaming_tool_markers, assigns),
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

  defp pending_user_message(messages, %{message: message} = request) when is_binary(message) do
    cond do
      persisted_user_message_for_request?(messages, request) ->
        nil

      true ->
        legacy_pending_user_message(messages, message)
    end
  end

  defp pending_user_message(_messages, _request), do: nil

  defp legacy_pending_user_message(messages, message) do
    case messages |> Enum.reverse() |> Enum.find(&(&1.role not in [:system, :tool])) do
      %{role: :user, content: ^message} -> nil
      _other -> message
    end
  end

  defp streaming_content(nil), do: ""
  defp streaming_content(%{content: content}) when is_binary(content), do: content
  defp streaming_content(_request), do: ""

  defp streaming_content(messages, request) do
    content = streaming_content(request)

    if content != "" and persisted_assistant_content_for_request?(messages, request, content) do
      ""
    else
      content
    end
  end

  defp streaming_tool_markers(_messages, nil), do: []

  defp streaming_tool_markers(messages, request) do
    request
    |> ToolTracking.tool_markers_from_events()
    |> drop_persisted_tool_markers(messages, request)
  end

  defp streaming_inline_surfaces(_conversation_id, [], _assigns), do: []

  defp streaming_inline_surfaces(conversation_id, tool_markers, assigns) do
    tool_markers
    |> ToolSurfaces.build_render_surfaces("streaming-#{conversation_id}", assigns)
    |> mark_surfaces_expanded(assigns)
  end

  # Only called from pending_user_message/2, which already narrows the
  # request to %{message: binary}.
  defp persisted_user_message_for_request?(messages, %{message: message} = request)
       when is_binary(message) do
    messages
    |> persisted_messages_for_request(request)
    |> Enum.any?(fn persisted_message ->
      persisted_message.role == :user and persisted_message.content == message
    end)
  end

  defp persisted_assistant_content_for_request?(messages, request, content)
       when is_binary(content) and content != "" do
    messages
    |> persisted_messages_for_request(request)
    |> Enum.any?(fn persisted_message ->
      persisted_message.role == :assistant and (persisted_message.content || "") == content
    end)
  end

  defp persisted_assistant_content_for_request?(_messages, _request, _content), do: false

  defp drop_persisted_tool_markers(tool_markers, messages, request) do
    persisted_markers = persisted_tool_markers_for_request(messages, request)

    {remaining, _persisted_markers} =
      Enum.reduce(tool_markers, {[], persisted_markers}, fn marker,
                                                            {remaining, persisted_markers} ->
        case pop_matching_tool_marker(persisted_markers, marker) do
          {nil, persisted_markers} -> {remaining ++ [marker], persisted_markers}
          {_matched, persisted_markers} -> {remaining, persisted_markers}
        end
      end)

    remaining
  end

  defp persisted_tool_markers_for_request(messages, request) do
    messages
    |> persisted_messages_for_request(request)
    |> Enum.flat_map(fn message ->
      if message.role == :assistant do
        ToolTracking.normalize_tool_calls(message.tool_calls)
      else
        []
      end
    end)
  end

  defp pop_matching_tool_marker(tool_markers, marker) do
    case Enum.find_index(tool_markers, &same_tool_marker?(&1, marker)) do
      nil -> {nil, tool_markers}
      index -> {Enum.at(tool_markers, index), List.delete_at(tool_markers, index)}
    end
  end

  defp same_tool_marker?(left, right) do
    cond do
      is_binary(left.id) and is_binary(right.id) ->
        left.id == right.id

      true ->
        left.name == right.name and (left.arguments || %{}) == (right.arguments || %{})
    end
  end

  defp persisted_messages_for_request(messages, request) do
    case request_started_at(request) do
      started_at when is_integer(started_at) ->
        Enum.filter(messages, fn message ->
          is_integer(message.created_at) and message.created_at >= started_at
        end)

      _other ->
        []
    end
  end

  defp request_started_at(%{started_at: started_at}) when is_integer(started_at), do: started_at
  defp request_started_at(_request), do: nil
end
