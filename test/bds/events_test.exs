defmodule BDS.EventsTest do
  use ExUnit.Case, async: false

  alias BDS.Events

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    :ok = Events.subscribe()

    temp_dir = Path.join(System.tmp_dir!(), "bds-events-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Events", data_path: temp_dir})
    %{project: project}
  end

  describe "entity_changed/3" do
    test "broadcasts the watcher-compatible payload" do
      :ok = Events.entity_changed("post", "abc", :updated)

      assert_receive {:entity_changed, %{entity: "post", entity_id: "abc", action: :updated}}
    end
  end

  describe "posts broadcast" do
    test "create, update, publish, delete", %{project: project} do
      {:ok, post} = BDS.Posts.create_post(%{project_id: project.id, title: "Hello"})
      post_id = post.id
      assert_receive {:entity_changed, %{entity: "post", entity_id: ^post_id, action: :created}}

      {:ok, _} = BDS.Posts.update_post(post_id, %{title: "Hello 2"})
      assert_receive {:entity_changed, %{entity: "post", entity_id: ^post_id, action: :updated}}

      {:ok, _} = BDS.Posts.publish_post(post_id)
      assert_receive {:entity_changed, %{entity: "post", entity_id: ^post_id, action: :updated}}

      {:ok, _} = BDS.Posts.delete_post(post_id)
      assert_receive {:entity_changed, %{entity: "post", entity_id: ^post_id, action: :deleted}}
    end
  end

  describe "tags broadcast" do
    test "create, update, delete", %{project: project} do
      {:ok, tag} = BDS.Tags.create_tag(%{project_id: project.id, name: "elixir"})
      tag_id = tag.id
      assert_receive {:entity_changed, %{entity: "tag", entity_id: ^tag_id, action: :created}}

      {:ok, _} = BDS.Tags.update_tag(tag_id, %{name: "erlang"})
      assert_receive {:entity_changed, %{entity: "tag", entity_id: ^tag_id, action: :updated}}

      {:ok, _} = BDS.Tags.delete_tag(tag_id)
      assert_receive {:entity_changed, %{entity: "tag", entity_id: ^tag_id, action: :deleted}}
    end
  end

  describe "templates broadcast" do
    test "create, update, delete", %{project: project} do
      {:ok, template} =
        BDS.Templates.create_template(%{
          project_id: project.id,
          title: "Article",
          kind: :post,
          content: "<article>{{ content }}</article>"
        })

      template_id = template.id

      assert_receive {:entity_changed,
                      %{entity: "template", entity_id: ^template_id, action: :created}}

      {:ok, _} = BDS.Templates.update_template(template_id, %{title: "Article 2"})

      assert_receive {:entity_changed,
                      %{entity: "template", entity_id: ^template_id, action: :updated}}

      {:ok, _} = BDS.Templates.delete_template(template_id)

      assert_receive {:entity_changed,
                      %{entity: "template", entity_id: ^template_id, action: :deleted}}
    end
  end

  describe "scripts broadcast" do
    test "create, update, delete", %{project: project} do
      {:ok, script} =
        BDS.Scripts.create_script(%{
          project_id: project.id,
          title: "hello",
          kind: :utility,
          content: "function main() end"
        })

      script_id = script.id
      assert_receive {:entity_changed, %{entity: "script", entity_id: ^script_id, action: :created}}

      {:ok, _} = BDS.Scripts.update_script(script_id, %{title: "hello2"})
      assert_receive {:entity_changed, %{entity: "script", entity_id: ^script_id, action: :updated}}

      {:ok, _} = BDS.Scripts.delete_script(script_id)
      assert_receive {:entity_changed, %{entity: "script", entity_id: ^script_id, action: :deleted}}
    end
  end

  describe "settings broadcast" do
    test "put_global_setting broadcasts settings_changed" do
      :ok = BDS.Settings.put_global_setting("ui.git_diff_view_style", "split")

      assert_receive {:settings_changed, "ui.git_diff_view_style"}
    end

    test "ui.language setting overrides the OS locale server-side" do
      :ok = BDS.Settings.put_global_setting("ui.language", "de")
      assert_receive {:settings_changed, "ui.language"}

      assert BDS.I18n.current_ui_locale() == "de"

      # Blank value falls back to the OS locale (en in the test env).
      :ok = BDS.Settings.put_global_setting("ui.language", "")
      assert BDS.I18n.current_ui_locale() == "en"
    end
  end
end
