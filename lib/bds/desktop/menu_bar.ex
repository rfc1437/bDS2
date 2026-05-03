defmodule BDS.Desktop.MenuBar do
  @moduledoc false

  use BDS.Desktop.MenuCompat
  alias BDS.Desktop.{ShellData, Shutdown, UILocale}
  alias BDS.UI.Commands
  alias BDS.UI.MenuBar, as: ShellMenuBar
  alias Desktop.OS
  alias Desktop.Window

  def groups(opts \\ []) do
    opts
    |> ShellMenuBar.default_groups()
    |> Enum.map(fn group ->
      %{
        id: group.id,
        label: group_label(group.id),
        items: Enum.map(group.items, &normalize_item/1)
      }
    end)
  end

  @impl true
  def mount(menu) do
    UILocale.put(ShellData.ui_language())

    {:ok,
     Desktop.Menu.assign(
       menu,
       :groups,
       groups(dev_mode?: Application.get_env(:bds, :dev_routes, false))
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <menubar>
      <%= for group <- @groups do %>
        <menu label={group.label}>
          <%= for item <- group.items do %>
            <%= if item.separator do %>
              <hr />
            <% else %>
              <item onclick={Atom.to_string(item.id)}>{item.native_label}</item>
            <% end %>
          <% end %>
        </menu>
      <% end %>
    </menubar>
    """
  end

  @impl true
  def handle_event("quit", menu) do
    Shutdown.request_quit()
    {:noreply, menu}
  end

  def handle_event("view_on_github", menu) do
    OS.launch_default_browser("https://github.com/rfc1437/bDS")
    {:noreply, menu}
  end

  def handle_event("open_in_browser", menu) do
    case BDS.Desktop.ShellCommands.execute("open_in_browser") do
      {:ok, %{url: url}} -> OS.launch_default_browser(url)
      _other -> :ok
    end

    {:noreply, menu}
  end

  def handle_event("open_data_folder", menu) do
    _ = BDS.Desktop.ShellCommands.execute("open_data_folder")
    {:noreply, menu}
  end

  def handle_event("report_issue", menu) do
    OS.launch_default_browser("https://github.com/rfc1437/bDS/issues")
    {:noreply, menu}
  end

  def handle_event(command, menu) do
    dispatch_shell_menu_action(command)
    {:noreply, menu}
  end

  @impl true
  def handle_info({:set_ui_locale, locale}, menu) do
    UILocale.put(locale)

    {:noreply,
     Desktop.Menu.assign(
       menu,
       :groups,
       groups(dev_mode?: Application.get_env(:bds, :dev_routes, false))
     )}
  end

  def handle_info(_, menu) do
    {:noreply, menu}
  end

  defp dispatch_shell_menu_action(command) when is_binary(command) do
    with webview when not is_nil(webview) <- webview(),
         payload <- Jason.encode!(%{action: command}),
         script <-
           "window.dispatchEvent(new CustomEvent('bds:native-menu-action', { detail: #{payload} })); true;" do
      :wx.set_env(Desktop.Env.wx_env())
      :wxWebView.runScript(webview, script)
    else
      _ -> :ok
    end
  end

  defp webview do
    try do
      Window.webview(BDS.Desktop.MainWindow.window_id())
    catch
      :exit, _ -> nil
    end
  end

  defp normalize_item(%{separator: true}), do: %{separator: true}

  defp normalize_item(item) do
    label = item_label(item.id)
    shortcut = Commands.accelerator_label(item.id)

    %{
      id: item.id,
      label: label,
      native_label: native_label(label, shortcut),
      separator: false,
      shortcut: shortcut
    }
  end

  defp native_label(label, nil), do: label
  defp native_label(label, shortcut), do: label <> "\t" <> shortcut

  defp group_label(:file), do: translate("menuBar.file")
  defp group_label(:edit), do: translate("menuBar.edit")
  defp group_label(:view), do: translate("menuBar.view")
  defp group_label(:blog), do: translate("menuBar.blog")
  defp group_label(:help), do: translate("menuBar.help")

  defp item_label(:new_post), do: translate("menuBar.newPost")
  defp item_label(:import_media), do: translate("menuBar.importMedia")
  defp item_label(:save), do: translate("menuBar.save")
  defp item_label(:open_in_browser), do: translate("menuBar.openInBrowser")
  defp item_label(:open_data_folder), do: translate("menuBar.openDataFolder")
  defp item_label(:close_tab), do: translate("menuBar.closeTab")
  defp item_label(:quit), do: translate("menuBar.quit")
  defp item_label(:undo), do: translate("menuBar.undo")
  defp item_label(:redo), do: translate("menuBar.redo")
  defp item_label(:cut), do: translate("menuBar.cut")
  defp item_label(:copy), do: translate("menuBar.copy")
  defp item_label(:paste), do: translate("menuBar.paste")
  defp item_label(:delete), do: translate("menuBar.delete")
  defp item_label(:select_all), do: translate("menuBar.selectAll")
  defp item_label(:find), do: translate("menuBar.find")
  defp item_label(:replace), do: translate("menuBar.replace")
  defp item_label(:edit_preferences), do: translate("menuBar.preferences")
  defp item_label(:view_posts), do: translate("menuBar.viewPosts")
  defp item_label(:view_media), do: translate("menuBar.viewMedia")
  defp item_label(:toggle_sidebar), do: translate("menuBar.toggleSidebar")
  defp item_label(:toggle_panel), do: translate("menuBar.togglePanel")
  defp item_label(:toggle_assistant_sidebar), do: translate("menuBar.toggleAssistantSidebar")
  defp item_label(:toggle_dev_tools), do: translate("menuBar.toggleDevTools")
  defp item_label(:reload), do: translate("menuBar.reload")
  defp item_label(:force_reload), do: translate("menuBar.forceReload")
  defp item_label(:reset_zoom), do: translate("menuBar.resetZoom")
  defp item_label(:zoom_in), do: translate("menuBar.zoomIn")
  defp item_label(:zoom_out), do: translate("menuBar.zoomOut")
  defp item_label(:toggle_full_screen), do: translate("menuBar.toggleFullScreen")
  defp item_label(:publish_selected), do: translate("menuBar.publishSelected")
  defp item_label(:preview_post), do: translate("menuBar.previewPost")
  defp item_label(:edit_menu), do: translate("menuBar.editMenu")
  defp item_label(:rebuild_database), do: translate("menuBar.rebuildDatabase")
  defp item_label(:reindex_text), do: translate("menuBar.reindexText")
  defp item_label(:rebuild_embedding_index), do: translate("menuBar.rebuildEmbeddingIndex")
  defp item_label(:metadata_diff), do: translate("menuBar.metadataDiff")
  defp item_label(:regenerate_calendar), do: translate("menuBar.regenerateCalendar")
  defp item_label(:validate_translations), do: translate("menuBar.validateTranslations")
  defp item_label(:fill_missing_translations), do: translate("menuBar.fillMissingTranslations")
  defp item_label(:find_duplicates), do: translate("menuBar.findDuplicates")
  defp item_label(:generate_sitemap), do: translate("menuBar.generateSite")
  defp item_label(:validate_site), do: translate("menuBar.validateSite")
  defp item_label(:upload_site), do: translate("menuBar.uploadSite")
  defp item_label(:about), do: translate("menuBar.about")
  defp item_label(:documentation), do: translate("menuBar.documentation")
  defp item_label(:api_documentation), do: translate("menuBar.apiDocumentation")
  defp item_label(:view_on_github), do: translate("menuBar.viewOnGithub")
  defp item_label(:report_issue), do: translate("menuBar.reportIssue")

  defp translate(text), do: ShellData.translate(text, %{}, UILocale.current())
end
