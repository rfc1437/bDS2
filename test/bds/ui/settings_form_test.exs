defmodule BDS.UI.SettingsFormTest do
  use ExUnit.Case, async: false

  alias BDS.UI.SettingsForm

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, :manual) end)

    temp_dir = Path.join(System.tmp_dir!(), "bds-settings-form-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Prefs", data_path: temp_dir})
    {:ok, _} = BDS.Projects.set_active_project(project.id)

    %{project: project}
  end

  defp field(form, key), do: Enum.find(form.fields, &(&1.key == key))

  defp values(form, overrides) do
    form.fields
    |> Map.new(fn f -> {f.key, f.value} end)
    |> Map.merge(overrides)
  end

  describe "project" do
    test "load exposes the project metadata as typed fields", %{project: project} do
      form = SettingsForm.load("project", project.id)

      assert field(form, "name").value == "Prefs"
      assert field(form, "name").type == :text
      assert field(form, "main_language").type == :enum
      assert "de" in field(form, "main_language").options
      assert field(form, "semantic_similarity_enabled").type == :bool
    end

    test "save writes through Metadata and keeps untouched values", %{project: project} do
      {:ok, _} = BDS.Metadata.update_project_metadata(project.id, %{pico_theme: "jade"})

      form = SettingsForm.load("project", project.id)

      :ok =
        SettingsForm.save(
          "project",
          project.id,
          values(form, %{
            "name" => "Renamed",
            "max_posts_per_page" => "25",
            "blog_languages" => "en, de",
            "semantic_similarity_enabled" => true
          })
        )

      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      assert metadata.name == "Renamed"
      assert metadata.max_posts_per_page == 25
      assert metadata.blog_languages == ["en", "de"]
      assert metadata.semantic_similarity_enabled
      assert metadata.pico_theme == "jade"
    end
  end

  describe "editor" do
    test "round-trips the global editor settings", %{project: project} do
      form = SettingsForm.load("editor", project.id)
      assert field(form, "default_mode").type == :enum

      :ok =
        SettingsForm.save(
          "editor",
          project.id,
          values(form, %{"default_mode" => "preview", "wrap_long_lines" => true})
        )

      assert BDS.Settings.get_global_setting("ui.preferred_editor_mode") == "preview"
      assert BDS.Settings.get_global_setting("ui.git_diff_word_wrap") == "true"

      reloaded = SettingsForm.load("editor", project.id)
      assert field(reloaded, "default_mode").value == "preview"
      assert field(reloaded, "wrap_long_lines").value == true
    end
  end

  describe "content" do
    test "edits category settings and adds new categories", %{project: project} do
      form = SettingsForm.load("content", project.id)
      assert field(form, "cat:aside:show_title").type == :bool

      :ok =
        SettingsForm.save(
          "content",
          project.id,
          values(form, %{
            "new_category" => "linkroll",
            "cat:article:render_in_lists" => false,
            "cat:article:title" => "Articles"
          })
        )

      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      assert "linkroll" in metadata.categories
      assert metadata.category_settings["article"]["render_in_lists"] == false
      assert metadata.category_settings["article"]["title"] == "Articles"
    end
  end

  describe "technology" do
    test "toggles semantic similarity without wiping the project", %{project: project} do
      form = SettingsForm.load("technology", project.id)
      refute field(form, "semantic_similarity_enabled").value

      :ok =
        SettingsForm.save(
          "technology",
          project.id,
          values(form, %{"semantic_similarity_enabled" => true})
        )

      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      assert metadata.semantic_similarity_enabled
      assert metadata.name == "Prefs"
    end
  end

  describe "publishing" do
    test "saves the SSH preferences", %{project: project} do
      form = SettingsForm.load("publishing", project.id)
      assert field(form, "ssh_mode").options == ["scp", "rsync"]

      :ok =
        SettingsForm.save(
          "publishing",
          project.id,
          values(form, %{"ssh_host" => "example.org", "ssh_mode" => "rsync"})
        )

      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      assert metadata.publishing_preferences["ssh_host"] == "example.org"
      assert metadata.publishing_preferences["ssh_mode"] == "rsync"
    end
  end

  describe "ai" do
    test "loads the AI form and saves prompt plus airplane mode", %{project: project} do
      form = SettingsForm.load("ai", project.id)
      assert field(form, "offline_mode").type == :bool
      assert field(form, "system_prompt").type == :text

      :ok =
        SettingsForm.save(
          "ai",
          project.id,
          values(form, %{"system_prompt" => "be terse", "offline_mode" => true})
        )

      assert BDS.Settings.get_global_setting("ai.system_prompt") == "be terse"
      assert BDS.AI.airplane_mode?()
    end
  end

  describe "style" do
    test "applies a theme without wiping other metadata", %{project: project} do
      form = SettingsForm.load("style", project.id)
      assert "jade" in field(form, "pico_theme").options

      :ok = SettingsForm.save("style", project.id, values(form, %{"pico_theme" => "jade"}))

      {:ok, metadata} = BDS.Metadata.get_project_metadata(project.id)
      assert metadata.pico_theme == "jade"
      assert metadata.name == "Prefs"
    end
  end

  describe "data" do
    test "shows the data folder read-only and save is a no-op", %{project: project} do
      form = SettingsForm.load("data", project.id)
      data_field = field(form, "data_path")
      assert data_field.type == :info
      assert data_field.value =~ "bds-settings-form"

      assert SettingsForm.save("data", project.id, %{}) == :ok
    end
  end

  describe "mcp" do
    test "lists the agents with supported ones as toggles", %{project: project} do
      form = SettingsForm.load("mcp", project.id)

      claude = field(form, "mcp:claude_code")
      assert claude.type == :bool
      assert is_boolean(claude.value)

      gemini = field(form, "mcp:gemini_cli")
      assert gemini.type == :info
    end
  end
end
