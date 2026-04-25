defmodule BDS.Desktop.MenuBar do
  @moduledoc false

  use BDS.Desktop.MenuCompat
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
    Window.quit()
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

  defp group_label(:file), do: "File"
  defp group_label(:edit), do: "Edit"
  defp group_label(:view), do: "View"
  defp group_label(:blog), do: "Blog"
  defp group_label(:help), do: "Help"

  defp item_label(:new_post), do: "New Post"
  defp item_label(:import_media), do: "Import Media"
  defp item_label(:save), do: "Save"
  defp item_label(:open_in_browser), do: "Open in Browser"
  defp item_label(:open_data_folder), do: "Open Data Folder"
  defp item_label(:close_tab), do: "Close Tab"
  defp item_label(:quit), do: "Quit"
  defp item_label(:undo), do: "Undo"
  defp item_label(:redo), do: "Redo"
  defp item_label(:cut), do: "Cut"
  defp item_label(:copy), do: "Copy"
  defp item_label(:paste), do: "Paste"
  defp item_label(:delete), do: "Delete"
  defp item_label(:select_all), do: "Select All"
  defp item_label(:find), do: "Find"
  defp item_label(:replace), do: "Replace"
  defp item_label(:edit_preferences), do: "Preferences"
  defp item_label(:view_posts), do: "Posts"
  defp item_label(:view_media), do: "Media"
  defp item_label(:toggle_sidebar), do: "Toggle Sidebar"
  defp item_label(:toggle_panel), do: "Toggle Panel"
  defp item_label(:toggle_assistant_sidebar), do: "Toggle Assistant Sidebar"
  defp item_label(:toggle_dev_tools), do: "Toggle Dev Tools"
  defp item_label(:reload), do: "Reload"
  defp item_label(:force_reload), do: "Force Reload"
  defp item_label(:reset_zoom), do: "Reset Zoom"
  defp item_label(:zoom_in), do: "Zoom In"
  defp item_label(:zoom_out), do: "Zoom Out"
  defp item_label(:toggle_full_screen), do: "Toggle Full Screen"
  defp item_label(:publish_selected), do: "Publish Selected"
  defp item_label(:preview_post), do: "Preview Post"
  defp item_label(:edit_menu), do: "Edit Menu"
  defp item_label(:rebuild_database), do: "Rebuild Database"
  defp item_label(:reindex_text), do: "Reindex Text"
  defp item_label(:rebuild_embedding_index), do: "Rebuild Embedding Index"
  defp item_label(:metadata_diff), do: "Metadata Diff"
  defp item_label(:regenerate_calendar), do: "Regenerate Calendar"
  defp item_label(:validate_translations), do: "Validate Translations"
  defp item_label(:fill_missing_translations), do: "Fill Missing Translations"
  defp item_label(:find_duplicates), do: "Find Duplicate Posts"
  defp item_label(:generate_sitemap), do: "Generate Sitemap"
  defp item_label(:validate_site), do: "Validate Site"
  defp item_label(:upload_site), do: "Upload Site"
  defp item_label(:about), do: "About"
  defp item_label(:documentation), do: "Documentation"
  defp item_label(:api_documentation), do: "API Documentation"
  defp item_label(:view_on_github), do: "View on GitHub"
  defp item_label(:report_issue), do: "Report Issue"
end
