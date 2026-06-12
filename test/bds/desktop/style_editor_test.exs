defmodule BDS.Desktop.ShellLive.SettingsEditor.StyleEditorTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.ShellLive.SettingsEditor.StyleEditor

  defp socket_with_assigns(extra \\ %{}) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}, workbench: nil}, extra)}
  end

  describe "build_style/1" do
    test "returns nil when no active project" do
      assigns = %{projects: %{active_project_id: nil}}
      assert StyleEditor.build_style(assigns) == nil
    end
  end

  describe "build_style/1 with real project" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
      temp_dir =
        Path.join(System.tmp_dir!(), "bds-style-editor-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      on_exit(fn -> File.rm_rf(temp_dir) end)

      {:ok, project} =
        BDS.Projects.create_project(%{name: "StyleEditor", data_path: temp_dir})

      %{project: project}
    end

    test "returns map with themes, selected_theme, applied_theme, preview_mode, preview_url", %{project: project} do
      assigns = %{projects: %{active_project_id: project.id}}

      result = StyleEditor.build_style(assigns)
      assert is_map(result)
      assert Map.has_key?(result, :themes)
      assert Map.has_key?(result, :selected_theme)
      assert Map.has_key?(result, :applied_theme)
      assert Map.has_key?(result, :preview_mode)
      assert Map.has_key?(result, :preview_url)
    end

    test "includes 20 themes", %{project: project} do
      assigns = %{projects: %{active_project_id: project.id}}
      result = StyleEditor.build_style(assigns)
      assert length(result.themes) == 20
    end

    test "each theme has required keys", %{project: project} do
      assigns = %{projects: %{active_project_id: project.id}}
      result = StyleEditor.build_style(assigns)
      theme = hd(result.themes)
      assert Map.has_key?(theme, :name)
      assert Map.has_key?(theme, :accent_color)
      assert Map.has_key?(theme, :light_bg_color)
      assert Map.has_key?(theme, :dark_bg_color)
    end

    test "includes default, amber, and zinc themes", %{project: project} do
      assigns = %{projects: %{active_project_id: project.id}}
      result = StyleEditor.build_style(assigns)
      names = Enum.map(result.themes, & &1.name)
      assert "default" in names
      assert "amber" in names
      assert "zinc" in names
    end

    test "preview_url includes theme and mode params", %{project: project} do
      assigns = %{projects: %{active_project_id: project.id}}
      result = StyleEditor.build_style(assigns)
      assert result.preview_url =~ "theme=default"
      assert result.preview_url =~ "mode=auto"
      assert result.preview_url =~ BDS.Preview.base_url() <> "/__style-preview"
    end

    test "preview_url reflects selected_theme", %{project: project} do
      assigns = %{
        projects: %{active_project_id: project.id},
        style_editor_theme: "amber"
      }

      result = StyleEditor.build_style(assigns)
      assert result.selected_theme == "amber"
      assert result.preview_url =~ "theme=amber"
    end

    test "preview_url reflects preview_mode", %{project: project} do
      assigns = %{
        projects: %{active_project_id: project.id},
        style_editor_preview_mode: "dark"
      }

      result = StyleEditor.build_style(assigns)
      assert result.preview_mode == "dark"
      assert result.preview_url =~ "mode=dark"
    end

    test "all 20 theme names are strings", %{project: project} do
      assigns = %{projects: %{active_project_id: project.id}}
      result = StyleEditor.build_style(assigns)
      assert Enum.all?(result.themes, &is_binary(&1.name))
    end
  end

  describe "theme_display_name/1" do
    test "replaces hyphens with spaces and capitalizes" do
      assert StyleEditor.theme_display_name("default") == "Default"
      assert StyleEditor.theme_display_name("amber") == "Amber"
    end

    test "handles empty string" do
      assert StyleEditor.theme_display_name("") == ""
    end
  end

  describe "select_style_theme/3" do
    test "updates style_editor_theme assign" do
      socket = socket_with_assigns()
      reload = fn s, _wb ->
        send(self(), {:reloaded, s})
        s
      end

      StyleEditor.select_style_theme(socket, "amber", reload)

      assert_received {:reloaded, updated_socket}
      assert updated_socket.assigns.style_editor_theme == "amber"
    end

    test "defaults to default when nil" do
      socket = socket_with_assigns()
      reload = fn s, _wb ->
        send(self(), {:reloaded, s})
        s
      end

      StyleEditor.select_style_theme(socket, nil, reload)

      assert_received {:reloaded, updated_socket}
      assert updated_socket.assigns.style_editor_theme == "default"
    end
  end

  describe "change_style_preview_mode/3" do
    test "updates style_editor_preview_mode assign" do
      socket = socket_with_assigns()
      reload = fn s, _wb ->
        send(self(), {:reloaded, s})
        s
      end

      StyleEditor.change_style_preview_mode(socket, "dark", reload)

      assert_received {:reloaded, updated_socket}
      assert updated_socket.assigns.style_editor_preview_mode == "dark"
    end

    test "defaults to auto when nil" do
      socket = socket_with_assigns()
      reload = fn s, _wb ->
        send(self(), {:reloaded, s})
        s
      end

      StyleEditor.change_style_preview_mode(socket, nil, reload)

      assert_received {:reloaded, updated_socket}
      assert updated_socket.assigns.style_editor_preview_mode == "auto"
    end
  end
end
