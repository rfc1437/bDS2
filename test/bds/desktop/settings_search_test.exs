defmodule BDS.Desktop.ShellLive.SettingsEditor.SettingsSearchTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.ShellLive.SettingsEditor
  alias BDS.Repo
  alias BDS.Settings.Setting

  describe "build_settings/1 — search filter" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
      temp_dir =
        Path.join(System.tmp_dir!(), "bds-settings-search-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      on_exit(fn -> File.rm_rf(temp_dir) end)

      {:ok, project} =
        BDS.Projects.create_project(%{name: "SearchFilter", data_path: temp_dir})

      %{project: project, temp_dir: temp_dir}
    end

    defp base_assigns(project_id, temp_dir, query) do
      %{
        projects: %{active_project_id: project_id},
        current_project: %{data_path: temp_dir},
        settings_editor_search: query,
        settings_editor_project_draft: %{},
        settings_editor_editor_draft: %{},
        settings_editor_ai_draft: %{},
        settings_editor_publishing_draft: %{},
        current_tab: %{type: :settings, id: "settings"},
        tab_meta: %{}
      }
    end

    test "empty query shows all sections visible", %{project: project, temp_dir: temp_dir} do
      result = SettingsEditor.build_settings(base_assigns(project.id, temp_dir, ""))

      assert result.project_visible?
      assert result.editor_visible?
      assert result.content_visible?
      assert result.ai_visible?
      assert result.technology_visible?
      assert result.publishing_visible?
      assert result.mcp_visible?
      assert result.data_visible?
    end

    test "matching query shows only relevant sections", %{project: project, temp_dir: temp_dir} do
      result = SettingsEditor.build_settings(base_assigns(project.id, temp_dir, "ai"))

      assert result.ai_visible?
      refute result.editor_visible?
      refute result.content_visible?
      refute result.publishing_visible?
    end

    test "query 'publishing' shows publishing section only", %{project: project, temp_dir: temp_dir} do
      result = SettingsEditor.build_settings(base_assigns(project.id, temp_dir, "publishing"))

      assert result.publishing_visible?
      refute result.editor_visible?
      refute result.ai_visible?
      refute result.technology_visible?
      refute result.mcp_visible?
      refute result.data_visible?
    end

    test "query 'mcp' shows mcp section", %{project: project, temp_dir: temp_dir} do
      result = SettingsEditor.build_settings(base_assigns(project.id, temp_dir, "mcp"))

      assert result.mcp_visible?
      refute result.editor_visible?
      refute result.ai_visible?
    end

    test "query 'claude' matches mcp section", %{project: project, temp_dir: temp_dir} do
      result = SettingsEditor.build_settings(base_assigns(project.id, temp_dir, "claude"))

      assert result.mcp_visible?
    end

    test "query 'data' shows data section", %{project: project, temp_dir: temp_dir} do
      result = SettingsEditor.build_settings(base_assigns(project.id, temp_dir, "data"))

      assert result.data_visible?
    end

    test "query 'editor' shows editor section", %{project: project, temp_dir: temp_dir} do
      result = SettingsEditor.build_settings(base_assigns(project.id, temp_dir, "editor"))

      assert result.editor_visible?
    end

    test "no match query shows no sections", %{project: project, temp_dir: temp_dir} do
      result = SettingsEditor.build_settings(base_assigns(project.id, temp_dir, "zzzzz"))

      refute result.project_visible?
      refute result.editor_visible?
      refute result.content_visible?
      refute result.ai_visible?
      refute result.technology_visible?
      refute result.publishing_visible?
      refute result.mcp_visible?
      refute result.data_visible?
    end
  end

  describe "build_settings/1 — returns nil without active project" do
    test "returns nil when active_project_id is nil" do
      assert SettingsEditor.build_settings(%{projects: %{active_project_id: nil}}) == nil
    end
  end

  describe "build_settings/1 — handles undecryptable API key gracefully" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
      temp_dir =
        Path.join(System.tmp_dir!(), "bds-settings-cipher-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      on_exit(fn -> File.rm_rf(temp_dir) end)

      {:ok, project} =
        BDS.Projects.create_project(%{name: "CipherTest", data_path: temp_dir})

      now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

      Repo.insert!(%Setting{
        key: "ai.online.url",
        value: "https://example.com",
        updated_at: now
      })

      Repo.insert!(%Setting{
        key: "ai.online.model",
        value: "gpt-4",
        updated_at: now
      })

      Repo.insert!(%Setting{
        key: "__encrypted_ai.online.api_key",
        value: "NOT_VALID_BASE64",
        updated_at: now
      })

      %{project: project, temp_dir: temp_dir}
    end

    test "does not crash when encrypted API key cannot be decrypted", %{
      project: project,
      temp_dir: temp_dir
    } do
      result =
        SettingsEditor.build_settings(%{
          projects: %{active_project_id: project.id},
          current_project: %{data_path: temp_dir},
          settings_editor_search: "",
          settings_editor_project_draft: %{},
          settings_editor_editor_draft: %{},
          settings_editor_ai_draft: %{},
          settings_editor_publishing_draft: %{},
          current_tab: %{type: :settings, id: "settings"},
          tab_meta: %{}
        })

      assert is_map(result)
      assert result.ai_visible?
    end
  end
end
