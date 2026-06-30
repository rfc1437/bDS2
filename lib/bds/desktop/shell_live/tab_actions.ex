defmodule BDS.Desktop.ShellLive.TabActions do
  @moduledoc false

  alias BDS.Desktop.ShellLive.{
    MediaEditor,
    MenuEditor,
    PostEditor,
    ScriptEditor,
    SocketState,
    SettingsEditor,
    TagsEditor,
    TemplateEditor
  }

  alias BDS.UI.Workbench

  def auto_save_current_post(
        %{assigns: %{current_tab: %{type: :post, id: post_id}, workbench: workbench}} = socket
      ) do
    if Workbench.dirty?(workbench, :post, post_id) do
      Phoenix.LiveView.send_update(PostEditor, id: "post-editor-#{post_id}", action: :auto_save)
    end

    socket
  end

  def auto_save_current_post(socket), do: socket

  def save_current_tab(%{assigns: %{current_tab: %{type: :post, id: post_id}}} = socket) do
    Phoenix.LiveView.send_update(PostEditor, id: "post-editor-#{post_id}", action: :save)
    socket
  end

  def save_current_tab(%{assigns: %{current_tab: %{type: :media, id: media_id}}} = socket) do
    Phoenix.LiveView.send_update(MediaEditor, id: "media-editor-#{media_id}", action: :save)
    socket
  end

  def save_current_tab(%{assigns: %{current_tab: %{type: :settings}}} = socket) do
    Phoenix.LiveView.send_update(SettingsEditor, id: "settings-editor", action: :save_project)
    socket
  end

  def save_current_tab(%{assigns: %{current_tab: %{type: :menu_editor}}} = socket) do
    Phoenix.LiveView.send_update(MenuEditor, id: "menu-editor", action: :save)
    socket
  end

  def save_current_tab(%{assigns: %{current_tab: %{type: :tags}}} = socket) do
    Phoenix.LiveView.send_update(TagsEditor, id: "tags-editor", action: :save)
    socket
  end

  def save_current_tab(%{assigns: %{current_tab: %{type: :scripts, id: script_id}}} = socket) do
    Phoenix.LiveView.send_update(ScriptEditor, id: "script-editor-#{script_id}", action: :save)
    socket
  end

  def save_current_tab(%{assigns: %{current_tab: %{type: :templates, id: template_id}}} = socket) do
    Phoenix.LiveView.send_update(TemplateEditor, id: "template-editor-#{template_id}", action: :save)
    socket
  end

  def save_current_tab(socket), do: SocketState.refresh_layout(socket, socket.assigns.workbench)

  def publish_current_tab(%{assigns: %{current_tab: %{type: :post, id: post_id}}} = socket) do
    Phoenix.LiveView.send_update(PostEditor, id: "post-editor-#{post_id}", action: :publish)
    socket
  end

  def publish_current_tab(socket), do: SocketState.refresh_layout(socket, socket.assigns.workbench)
end
