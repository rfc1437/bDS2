defmodule BDS.Desktop.ShellLive.ChatSurface do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.{ChatEditor, TabHelpers}
  alias BDS.UI.Workbench

  @doc """
  Handle a chat-surface action from a chat message. Receives callbacks for
  `reload_shell/2` and `open_sidebar_item/3` to remain decoupled from
  `BDS.Desktop.ShellLive` private state.
  """
  def handle_action(socket, params, callbacks) do
    surface_id = Map.get(params, "surface-id", "")

    payload =
      params
      |> Map.get("payload")
      |> decode_payload()
      |> maybe_put_form_data(socket, surface_id)

    case normalize_action(Map.get(params, "action", "")) do
      :open_post ->
        case Map.get(payload, "postId") || Map.get(payload, "post_id") do
          post_id when is_binary(post_id) and post_id != "" ->
            socket
            |> clear_action_error()
            |> callbacks.open_sidebar.(
              %{
                "route" => "post",
                "id" => post_id,
                "title" => TabHelpers.post_title(post_id),
                "subtitle" => TabHelpers.post_subtitle(post_id)
              },
              :pin
            )

          _other ->
            ChatEditor.set_action_error(
              socket,
              socket.assigns.current_tab.id,
              "Invalid payload for openPost action",
              callbacks.reload
            )
        end

      :open_media ->
        case Map.get(payload, "mediaId") || Map.get(payload, "media_id") do
          media_id when is_binary(media_id) and media_id != "" ->
            socket
            |> clear_action_error()
            |> callbacks.open_sidebar.(
              %{
                "route" => "media",
                "id" => media_id,
                "title" => TabHelpers.media_title(media_id),
                "subtitle" => TabHelpers.media_subtitle(media_id)
              },
              :pin
            )

          _other ->
            ChatEditor.set_action_error(
              socket,
              socket.assigns.current_tab.id,
              "Invalid payload for openMedia action",
              callbacks.reload
            )
        end

      :open_settings ->
        socket
        |> clear_action_error()
        |> callbacks.open_sidebar.(
          %{"route" => "settings", "id" => "settings-ai", "title" => "Settings", "subtitle" => "AI"},
          :pin
        )

      :open_chat ->
        chat_id =
          Map.get(payload, "conversationId") || Map.get(payload, "conversation_id") ||
            socket.assigns.current_tab.id

        socket
        |> clear_action_error()
        |> callbacks.open_sidebar.(
          %{
            "route" => "chat",
            "id" => chat_id,
            "title" => Map.get(payload, "title", "Chat"),
            "subtitle" => Map.get(payload, "subtitle", "")
          },
          :pin
        )

      :switch_view ->
        case safe_existing_atom(Map.get(payload, "view")) do
          nil ->
            ChatEditor.set_action_error(
              socket,
              socket.assigns.current_tab.id,
              "Invalid payload for switchView action",
              callbacks.reload
            )

          view ->
            socket
            |> clear_action_error()
            |> callbacks.reload.(Workbench.click_activity(socket.assigns.workbench, view))
        end

      :toggle_sidebar ->
        socket
        |> clear_action_error()
        |> callbacks.reload.(Workbench.toggle_sidebar(socket.assigns.workbench))

      :toggle_panel ->
        socket
        |> clear_action_error()
        |> callbacks.reload.(Workbench.toggle_panel(socket.assigns.workbench))

      :toggle_assistant_sidebar ->
        socket
        |> clear_action_error()
        |> callbacks.reload.(Workbench.toggle_assistant_sidebar(socket.assigns.workbench))

      :unknown ->
        ChatEditor.set_action_error(
          socket,
          socket.assigns.current_tab.id,
          "Unsupported assistant action",
          callbacks.reload
        )
    end
  end

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

  def clear_action_error(%{assigns: %{current_tab: %{type: :chat, id: conversation_id}}} = socket) do
    assign(socket, :chat_editor_action_errors, Map.delete(socket.assigns.chat_editor_action_errors, conversation_id))
  end

  def clear_action_error(socket), do: socket

  defp decode_payload(nil), do: %{}
  defp decode_payload(""), do: %{}

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp decode_payload(_payload), do: %{}

  defp maybe_put_form_data(payload, socket, surface_id) when is_binary(surface_id) and surface_id != "" do
    form_data = ChatEditor.current_surface_data(socket, surface_id)

    if form_data == %{} do
      payload
    else
      Map.put(payload, "formData", form_data)
    end
  end

  defp maybe_put_form_data(payload, _socket, _surface_id), do: payload

  defp normalize_action(action) do
    action
    |> to_string()
    |> String.replace("_", "")
    |> String.downcase()
    |> case do
      "openpost" -> :open_post
      "openmedia" -> :open_media
      "opensettings" -> :open_settings
      "openchat" -> :open_chat
      "switchview" -> :switch_view
      "setactiveview" -> :switch_view
      "togglesidebar" -> :toggle_sidebar
      "togglepanel" -> :toggle_panel
      "openpanel" -> :toggle_panel
      "toggleassistantsidebar" -> :toggle_assistant_sidebar
      _other -> :unknown
    end
  end

  defp safe_existing_atom(action) when is_binary(action) do
    String.to_existing_atom(action)
  rescue
    ArgumentError -> nil
  end

  defp safe_existing_atom(_), do: nil

  defp assistant_reply(socket) do
    if socket.assigns.offline_mode do
      ShellData.translate("Automatic AI actions stay gated by airplane mode.", %{}, socket.assigns.page_language)
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
