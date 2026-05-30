defmodule BDS.Desktop.ShellLive.SettingsEditor.ManagedCategoriesTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.ShellLive.SettingsEditor.ManagedCategories

  defp socket_with_assigns(extra \\ %{}) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}, workbench: nil}, extra)}
  end

  describe "protected_category?/1" do
    test "returns true for article, aside, page, picture" do
      assert ManagedCategories.protected_category?("article")
      assert ManagedCategories.protected_category?("aside")
      assert ManagedCategories.protected_category?("page")
      assert ManagedCategories.protected_category?("picture")
    end

    test "returns false for non-protected categories" do
      refute ManagedCategories.protected_category?("news")
      refute ManagedCategories.protected_category?("links")
      refute ManagedCategories.protected_category?("random")
    end
  end

  describe "category_rows/1" do
    test "returns a row per category" do
      metadata = %{
        categories: ["article", "aside", "page", "picture", "notes"],
        category_settings: %{
          "article" => %{"title" => "Articles", "render_in_lists" => true, "show_title" => true},
          "notes" => %{"title" => "My Notes", "render_in_lists" => true, "show_title" => false}
        }
      }

      rows = ManagedCategories.category_rows(metadata)
      assert length(rows) == 5
    end

    test "each row has expected keys" do
      metadata = %{
        categories: ["article"],
        category_settings: %{"article" => %{"title" => "Articles"}}
      }

      rows = ManagedCategories.category_rows(metadata)
      row = hd(rows)
      assert Map.has_key?(row, :name)
      assert Map.has_key?(row, :title)
      assert Map.has_key?(row, :render_in_lists)
      assert Map.has_key?(row, :show_title)
      assert Map.has_key?(row, :post_template_slug)
      assert Map.has_key?(row, :list_template_slug)
      assert Map.has_key?(row, :protected?)
    end

    test "maps title from category_settings" do
      metadata = %{
        categories: ["article", "notes"],
        category_settings: %{
          "article" => %{"title" => "Articles"},
          "notes" => %{"title" => "My Notes"}
        }
      }

      rows = ManagedCategories.category_rows(metadata)
      article = Enum.find(rows, &(&1.name == "article"))
      assert article.title == "Articles"

      notes = Enum.find(rows, &(&1.name == "notes"))
      assert notes.title == "My Notes"
    end

    test "falls back to category name when no title in settings" do
      rows = ManagedCategories.category_rows(%{
        categories: ["custom-cat"],
        category_settings: %{}
      })
      row = hd(rows)
      assert row.title == "custom-cat"
    end

    test "marks protected categories" do
      rows = ManagedCategories.category_rows(%{
        categories: ["article", "notes"],
        category_settings: %{}
      })
      article = Enum.find(rows, &(&1.name == "article"))
      notes = Enum.find(rows, &(&1.name == "notes"))
      assert article.protected?
      refute notes.protected?
    end

    test "applies default render_in_lists and show_title when not in settings" do
      rows = ManagedCategories.category_rows(%{
        categories: ["custom"],
        category_settings: %{}
      })
      row = hd(rows)
      assert row.render_in_lists == true
      assert row.show_title == true
    end

    test "default template slugs are empty strings" do
      rows = ManagedCategories.category_rows(%{
        categories: ["custom"],
        category_settings: %{}
      })
      row = hd(rows)
      assert row.post_template_slug == ""
      assert row.list_template_slug == ""
    end
  end

  describe "update_new_category/3" do
    test "sets settings_editor_new_category assign" do
      socket = socket_with_assigns()
      reload = fn s, _wb ->
        send(self(), {:reloaded, s})
        s
      end

      ManagedCategories.update_new_category(socket, "my-cat", reload)

      assert_received {:reloaded, updated}
      assert updated.assigns.settings_editor_new_category == "my-cat"
    end

    test "defaults to empty string when nil" do
      socket = socket_with_assigns()
      reload = fn s, _wb ->
        send(self(), {:reloaded, s})
        s
      end

      ManagedCategories.update_new_category(socket, nil, reload)

      assert_received {:reloaded, updated}
      assert updated.assigns.settings_editor_new_category == ""
    end
  end

  describe "add_category/3" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
      temp_dir =
        Path.join(System.tmp_dir!(), "bds-managed-cat-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      on_exit(fn -> File.rm_rf(temp_dir) end)

      {:ok, project} =
        BDS.Projects.create_project(%{name: "AddCategory", data_path: temp_dir})

      %{project: project}
    end

    test "adds a new category via Metadata", %{project: project} do
      socket = socket_with_assigns(%{
        projects: %{active_project_id: project.id},
        settings_editor_new_category: "test-category"
      })

      reload = fn s, _wb ->
        send(self(), :reloaded)
        s
      end

      append_output = fn _socket, _title, _msg, _nil, _kind -> socket end

      ManagedCategories.add_category(socket, reload, append_output)

      assert_received :reloaded
      assert {:ok, meta} = BDS.Metadata.get_project_metadata(project.id)
      assert "test-category" in meta.categories
    end

    test "clears new_category input after successful add", %{project: project} do
      socket = socket_with_assigns(%{
        projects: %{active_project_id: project.id},
        settings_editor_new_category: "test-category"
      })

      reload = fn s, _wb -> s end
      append_output = fn _socket, _title, _msg, _nil, _kind -> socket end

      result = ManagedCategories.add_category(socket, reload, append_output)
      assert result.assigns.settings_editor_new_category == ""
    end

    test "shows error for empty category name", %{project: project} do
      socket = socket_with_assigns(%{
        projects: %{active_project_id: project.id},
        settings_editor_new_category: ""
      })

      reload = fn s, _wb -> s end
      append_output = fn _socket, _title, _msg, _nil, _kind ->
        send(self(), :error_appended)
        socket
      end

      ManagedCategories.add_category(socket, reload, append_output)

      assert_received :error_appended
    end
  end

  describe "save_category/4" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
      temp_dir =
        Path.join(System.tmp_dir!(), "bds-managed-cat-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      on_exit(fn -> File.rm_rf(temp_dir) end)

      {:ok, project} =
        BDS.Projects.create_project(%{name: "SaveCategory", data_path: temp_dir})

      %{project: project}
    end

    test "saves category settings via Metadata", %{project: project} do
      socket = socket_with_assigns(%{projects: %{active_project_id: project.id}})

      params = %{
        "category" => "article",
        "title" => "Articles",
        "render_in_lists" => "true",
        "show_title" => "true",
        "post_template_slug" => "",
        "list_template_slug" => ""
      }

      reload = fn s, _wb ->
        send(self(), :reloaded)
        s
      end

      append_output = fn _socket, _title, _msg, _nil, _kind ->
        send(self(), :error_appended)
        socket
      end

      ManagedCategories.save_category(socket, params, reload, append_output)

      assert_received :reloaded
      refute_received :error_appended

      assert {:ok, meta} = BDS.Metadata.get_project_metadata(project.id)
      cat_settings = meta.category_settings["article"]
      assert cat_settings["title"] == "Articles"
      assert cat_settings["render_in_lists"] == true
      assert cat_settings["show_title"] == true
    end

    test "saves template slug for a category", %{project: project} do
      socket = socket_with_assigns(%{projects: %{active_project_id: project.id}})

      params = %{
        "category" => "article",
        "title" => "Articles",
        "render_in_lists" => "true",
        "show_title" => "true",
        "post_template_slug" => "my-post",
        "list_template_slug" => "my-list"
      }

      reload = fn s, _wb -> s end
      append_output = fn _socket, _title, _msg, _nil, _kind -> socket end

      ManagedCategories.save_category(socket, params, reload, append_output)

      assert {:ok, meta} = BDS.Metadata.get_project_metadata(project.id)
      cat_settings = meta.category_settings["article"]
      assert cat_settings["post_template_slug"] == "my-post"
      assert cat_settings["list_template_slug"] == "my-list"
    end
  end

  describe "reset_categories/3" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
      temp_dir =
        Path.join(System.tmp_dir!(), "bds-managed-cat-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      on_exit(fn -> File.rm_rf(temp_dir) end)

      {:ok, project} =
        BDS.Projects.create_project(%{name: "ResetCategories", data_path: temp_dir})

      BDS.Metadata.add_category(project.id, "custom-1")
      BDS.Metadata.add_category(project.id, "custom-2")

      %{project: project}
    end

    test "removes non-protected categories and restores defaults", %{project: project} do
      assert {:ok, before} = BDS.Metadata.get_project_metadata(project.id)
      assert "custom-1" in before.categories
      assert "custom-2" in before.categories

      socket = socket_with_assigns(%{
        projects: %{active_project_id: project.id},
        settings_editor_new_category: "dirty"
      })

      reload = fn s, _wb ->
        send(self(), :reloaded)
        s
      end

      append_output = fn _socket, _title, _msg, _nil, _kind -> socket end

      ManagedCategories.reset_categories(socket, reload, append_output)

      assert_received :reloaded

      assert {:ok, after_meta} = BDS.Metadata.get_project_metadata(project.id)
      refute "custom-1" in after_meta.categories
      refute "custom-2" in after_meta.categories

      assert "article" in after_meta.categories
      assert "aside" in after_meta.categories
      assert "page" in after_meta.categories
      assert "picture" in after_meta.categories
    end

    test "preserves protected categories during reset", %{project: project} do
      socket = socket_with_assigns(%{
        projects: %{active_project_id: project.id},
        settings_editor_new_category: ""
      })

      reload = fn s, _wb -> s end
      append_output = fn _socket, _title, _msg, _nil, _kind -> socket end

      ManagedCategories.reset_categories(socket, reload, append_output)

      assert {:ok, meta} = BDS.Metadata.get_project_metadata(project.id)
      assert "article" in meta.categories
      assert "aside" in meta.categories
    end

    test "clears new_category input after reset", %{project: project} do
      socket = socket_with_assigns(%{
        projects: %{active_project_id: project.id},
        settings_editor_new_category: "dirty"
      })

      reload = fn s, _wb -> s end
      append_output = fn _socket, _title, _msg, _nil, _kind -> socket end

      result = ManagedCategories.reset_categories(socket, reload, append_output)
      assert result.assigns.settings_editor_new_category == ""
    end

    test "restores default category settings after reset", %{project: project} do
      socket = socket_with_assigns(%{
        projects: %{active_project_id: project.id},
        settings_editor_new_category: ""
      })

      reload = fn s, _wb -> s end
      append_output = fn _socket, _title, _msg, _nil, _kind -> socket end

      ManagedCategories.reset_categories(socket, reload, append_output)

      assert {:ok, meta} = BDS.Metadata.get_project_metadata(project.id)
      article = meta.category_settings["article"]
      assert article["title"] == "article"
      assert article["render_in_lists"] == true
      assert article["show_title"] == true
    end
  end

  describe "remove_category/4" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
      temp_dir =
        Path.join(System.tmp_dir!(), "bds-managed-categories-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)

      on_exit(fn -> File.rm_rf(temp_dir) end)

      {:ok, project} =
        BDS.Projects.create_project(%{name: "ProtectedCategories", data_path: temp_dir})

      %{project: project, temp_dir: temp_dir}
    end

    test "rejects deletion of protected category with error output", %{project: project} do
      socket = socket_with_assigns(%{projects: %{active_project_id: project.id}})

      append_output = fn _socket, _title, _msg, _nil, _kind ->
        send(self(), :error_appended)
        socket
      end

      ManagedCategories.remove_category(
        socket,
        "article",
        fn s, _wb -> s end,
        append_output
      )

      assert_received :error_appended
    end

    test "rejects deletion of all protected categories", %{project: project} do
      socket = socket_with_assigns(%{projects: %{active_project_id: project.id}})

      for cat <- ["article", "aside", "page", "picture"] do
        append_output = fn _socket, _title, _msg, _nil, _kind ->
          send(self(), {:rejected, cat})
          socket
        end

        ManagedCategories.remove_category(
          socket,
          cat,
          fn s, _wb -> s end,
          append_output
        )

        assert_received {:rejected, ^cat}
      end
    end

    test "allows deletion of non-protected category via Metadata.remove_category", %{
      project: project
    } do
      socket = socket_with_assigns(%{projects: %{active_project_id: project.id}})

      BDS.Metadata.add_category(project.id, "test-cat")
      assert {:ok, meta} = BDS.Metadata.get_project_metadata(project.id)
      assert "test-cat" in meta.categories

      append_output = fn _socket, _title, _msg, _nil, _kind ->
        send(self(), :error_called)
        socket
      end

      ManagedCategories.remove_category(
        socket,
        "test-cat",
        fn s, _wb -> s end,
        append_output
      )

      refute_received :error_called

      assert {:ok, meta} = BDS.Metadata.get_project_metadata(project.id)
      refute "test-cat" in meta.categories
    end
  end
end
