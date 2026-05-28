defmodule BDS.Desktop.ShellLive.Bridges do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, send_update: 2]

  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.{ChatEditor, PostEditor}
  alias BDS.Desktop.ShellLive.{CliSync, SessionUtil}
  alias BDS.UI.Workbench

  @refreshable_tab_meta_types [:import, :chat]

  @spec handle_info(tuple() | atom(), Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}

  # ── Generic editor notifications (sent via Notify module) ────────────────

  def handle_info({:editor_output, title, message, detail, level}, socket, callbacks) do
    {:noreply, callbacks.append_output.(socket, title, message, detail, level)}
  end

  def handle_info({:editor_tab_meta, type, id, updates}, socket, callbacks)
      when is_atom(type) and is_map(updates) do
    key = {type, id}
    current_meta = Map.get(socket.assigns.tab_meta, key, %{})
    next_meta = Map.merge(current_meta, updates)
    tab_meta = Map.put(socket.assigns.tab_meta, key, next_meta)

    socket = assign(socket, :tab_meta, tab_meta)

    if type in @refreshable_tab_meta_types do
      {:noreply, callbacks.refresh_sidebar.(socket, socket.assigns.workbench)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:editor_dirty, type, id, dirty?}, socket, _callbacks) do
    workbench =
      if dirty? do
        Workbench.mark_dirty(socket.assigns.workbench, type, id)
      else
        Workbench.clear_dirty(socket.assigns.workbench, type, id)
      end

    {:noreply, assign(socket, :workbench, workbench)}
  end

  @default_auto_save_delay 3000

  def handle_info({:schedule_auto_save, type, id}, socket, _callbacks) do
    timers = socket.assigns[:auto_save_timers] || %{}
    key = {type, id}

    case Map.get(timers, key) do
      nil -> :ok
      old_ref -> Process.cancel_timer(old_ref)
    end

    delay = Application.get_env(:bds, :auto_save_delay, @default_auto_save_delay)
    ref = Process.send_after(self(), {:auto_save_fire, type, id}, delay)
    {:noreply, assign(socket, :auto_save_timers, Map.put(timers, key, ref))}
  end

  def handle_info({:cancel_auto_save, type, id}, socket, _callbacks) do
    timers = socket.assigns[:auto_save_timers] || %{}
    key = {type, id}

    case Map.get(timers, key) do
      nil -> :ok
      old_ref -> Process.cancel_timer(old_ref)
    end

    {:noreply, assign(socket, :auto_save_timers, Map.delete(timers, key))}
  end

  def handle_info({:auto_save_fire, :post, post_id}, socket, _callbacks) do
    timers = socket.assigns[:auto_save_timers] || %{}
    send_update(PostEditor, id: "post-editor-#{post_id}", action: :save)
    {:noreply, assign(socket, :auto_save_timers, Map.delete(timers, {:post, post_id}))}
  end

  def handle_info({:editor_command, action, params}, socket, callbacks) do
    {:noreply, callbacks.apply_shell_command.(socket, action, params)}
  end

  # ── Shared actions (already generic) ─────────────────────────────────────

  def handle_info({:open_sidebar_item, params, intent}, socket, callbacks) do
    {:noreply, callbacks.open_sidebar.(socket, params, intent)}
  end

  def handle_info(:reload_shell, socket, callbacks) do
    {:noreply, callbacks.reload.(socket, socket.assigns.workbench)}
  end

  def handle_info({:close_tab, type, id}, socket, callbacks) do
    {:noreply,
     callbacks.refresh_layout.(socket, Workbench.close_tab(socket.assigns.workbench, type, id))}
  end

  def handle_info(:tags_changed, socket, callbacks) do
    {:noreply, callbacks.refresh_content.(socket, socket.assigns.workbench)}
  end

  def handle_info(:settings_changed, socket, callbacks) do
    {:noreply, callbacks.reload.(socket, socket.assigns.workbench)}
  end

  # ── Chat editor messages (sent from AI streaming, not from Notify) ──────

  def handle_info({:chat_tool_call, conversation_id, tool_call}, socket, _callbacks) do
    send_update(ChatEditor,
      id: "chat-editor-#{conversation_id}",
      action: :note_tool_call,
      tool_call: tool_call
    )

    {:noreply, socket}
  end

  def handle_info({:chat_tool_result, conversation_id, name}, socket, _callbacks) do
    send_update(ChatEditor,
      id: "chat-editor-#{conversation_id}",
      action: :note_tool_result,
      name: name
    )

    {:noreply, socket}
  end

  def handle_info({:chat_streaming_content, conversation_id, content}, socket, _callbacks) do
    send_update(ChatEditor,
      id: "chat-editor-#{conversation_id}",
      action: :note_streaming_content,
      content: content
    )

    {:noreply, socket}
  end

  def handle_info({:chat_editor_task_started, conversation_id, ref}, socket, _callbacks) do
    refs = Map.put(socket.assigns.chat_editor_request_refs, ref, conversation_id)
    {:noreply, assign(socket, :chat_editor_request_refs, refs)}
  end

  def handle_info({:chat_editor_task_cancelled, _conversation_id, ref}, socket, _callbacks) do
    refs = Map.delete(socket.assigns.chat_editor_request_refs, ref)
    {:noreply, assign(socket, :chat_editor_request_refs, refs)}
  end

  def handle_info({:persist_surface_state, conversation_id}, socket, _callbacks) do
    send_update(ChatEditor,
      id: "chat-editor-#{conversation_id}",
      action: :persist_surface_state
    )

    {:noreply, socket}
  end

  def handle_info({:chat_editor_toggle_sidebar}, socket, callbacks) do
    {:noreply,
     callbacks.refresh_layout.(socket, Workbench.toggle_sidebar(socket.assigns.workbench))}
  end

  def handle_info({:chat_editor_toggle_panel}, socket, callbacks) do
    {:noreply,
     callbacks.refresh_layout.(socket, Workbench.toggle_panel(socket.assigns.workbench))}
  end

  def handle_info({:chat_editor_toggle_assistant_sidebar}, socket, callbacks) do
    {:noreply,
     callbacks.refresh_layout.(
       socket,
       Workbench.toggle_assistant_sidebar(socket.assigns.workbench)
     )}
  end

  def handle_info({:chat_editor_switch_view, view}, socket, callbacks) do
    {:noreply,
     callbacks.refresh_sidebar.(socket, Workbench.click_activity(socket.assigns.workbench, view))}
  end

  # ── Post editor cross-component messages (sent from OverlayManager) ─────

  def handle_info({:post_editor_insert_content, post_id, content}, socket, _callbacks) do
    send_update(PostEditor,
      id: "post-editor-#{post_id}",
      action: :insert_content,
      content: content
    )

    {:noreply, socket}
  end

  def handle_info({:post_editor_translate, post_id, language}, socket, _callbacks) do
    send_update(PostEditor, id: "post-editor-#{post_id}", action: :translate, language: language)
    {:noreply, socket}
  end

  def handle_info({:post_editor_apply_ai_suggestions, post_id, fields}, socket, _callbacks) do
    send_update(PostEditor,
      id: "post-editor-#{post_id}",
      action: :apply_ai_suggestions,
      fields: fields
    )

    {:noreply, socket}
  end

  # ── External system messages ─────────────────────────────────────────────

  def handle_info({:entity_changed, payload}, socket, callbacks) when is_map(payload) do
    {:noreply, CliSync.apply_entity_change(socket, payload, callbacks.refresh_content)}
  end

  def handle_info(:refresh_task_status, socket, callbacks) do
    raw_task_status = BDS.Tasks.status_snapshot()

    socket =
      case SessionUtil.next_completed_task_result(socket, raw_task_status) do
        nil ->
          task_status =
            BDS.Desktop.ShellLive.TaskLocalization.localize_task_status(
              raw_task_status,
              socket.assigns.page_language
            )

          socket
          |> assign(:task_status, task_status)
          |> assign(:editor_meta, ShellData.editor_meta(task_status))
          |> assign(
            :status,
            ShellData.status_bar(
              socket.assigns.workbench,
              task_status,
              socket.assigns.dashboard,
              ui_language: socket.assigns.page_language,
              offline_mode: socket.assigns.offline_mode
            )
          )

        task ->
          socket
          |> SessionUtil.mark_task_result_handled(task.id)
          |> callbacks.apply_shell_command_result.(task.result)
      end

    if connected?(socket) do
      Process.send_after(self(), :refresh_task_status, BDS.Desktop.ShellLive.refresh_interval())
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket, _callbacks), do: {:noreply, socket}
end
