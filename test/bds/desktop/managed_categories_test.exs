defmodule BDS.Desktop.ShellLive.SettingsEditor.ManagedCategoriesTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.ShellLive.SettingsEditor.ManagedCategories

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
      socket = %{assigns: %{projects: %{active_project_id: project.id}, workbench: nil}}

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
      socket = %{assigns: %{projects: %{active_project_id: project.id}, workbench: nil}}

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
      socket = %{
        assigns: %{
          projects: %{active_project_id: project.id},
          workbench: nil
        }
      }

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
