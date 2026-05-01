defmodule BDS.UI.SidebarTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.AI
  alias BDS.ImportDefinitions
  alias BDS.Media
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Scripts
  alias BDS.Templates
  alias BDS.UI.Sidebar

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir = Path.join(System.tmp_dir!(), "bds-sidebar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = Projects.create_project(%{name: "Sidebar", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "database-backed sidebar views follow the old app ordering keys", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, draft_old} = Posts.create_post(%{project_id: project.id, title: "Draft Old"})
    assert {:ok, draft_new} = Posts.create_post(%{project_id: project.id, title: "Draft New"})

    assert {:ok, published_old} =
             Posts.create_post(%{project_id: project.id, title: "Published Old"})

    assert {:ok, published_new} =
             Posts.create_post(%{project_id: project.id, title: "Published New"})

    assert {:ok, archived_old} =
             Posts.create_post(%{project_id: project.id, title: "Archived Old"})

    assert {:ok, archived_new} =
             Posts.create_post(%{project_id: project.id, title: "Archived New"})

    update_post_sidebar_row(draft_old.id, created_at: 1_000, updated_at: 9_000)
    update_post_sidebar_row(draft_new.id, created_at: 2_000, updated_at: 1_000)

    update_post_sidebar_row(
      published_old.id,
      status: :published,
      created_at: 3_000,
      updated_at: 9_000,
      published_at: 3_000,
      file_path: "posts/published-old.md"
    )

    update_post_sidebar_row(
      published_new.id,
      status: :published,
      created_at: 4_000,
      updated_at: 1_000,
      published_at: 4_000,
      file_path: "posts/published-new.md"
    )

    update_post_sidebar_row(archived_old.id,
      status: :archived,
      created_at: 5_000,
      updated_at: 9_000
    )

    update_post_sidebar_row(archived_new.id,
      status: :archived,
      created_at: 6_000,
      updated_at: 1_000
    )

    old_media_path = Path.join(temp_dir, "old-media.txt")
    new_media_path = Path.join(temp_dir, "new-media.txt")
    File.write!(old_media_path, "old media")
    File.write!(new_media_path, "new media")

    assert {:ok, old_media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: old_media_path,
               title: "Old Media"
             })

    assert {:ok, new_media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: new_media_path,
               title: "New Media"
             })

    update_media_sidebar_row(old_media.id, created_at: 7_000, updated_at: 9_000)
    update_media_sidebar_row(new_media.id, created_at: 8_000, updated_at: 1_000)

    assert {:ok, old_script} =
             Scripts.create_script(%{
               project_id: project.id,
               title: "Old Script",
               kind: :utility,
               content: "print('old')",
               entrypoint: "main"
             })

    assert {:ok, new_script} =
             Scripts.create_script(%{
               project_id: project.id,
               title: "New Script",
               kind: :utility,
               content: "print('new')",
               entrypoint: "main"
             })

    update_script_sidebar_row(old_script.id, 9_000)
    update_script_sidebar_row(new_script.id, 10_000)

    assert {:ok, old_template} =
             Templates.create_template(%{
               project_id: project.id,
               title: "Old Template",
               kind: :post,
               content: "old"
             })

    assert {:ok, new_template} =
             Templates.create_template(%{
               project_id: project.id,
               title: "New Template",
               kind: :post,
               content: "new"
             })

    update_template_sidebar_row(old_template.id, 11_000)
    update_template_sidebar_row(new_template.id, 12_000)

    assert {:ok, old_chat} = AI.start_chat(%{title: "Old Chat"})
    assert {:ok, new_chat} = AI.start_chat(%{title: "New Chat"})
    update_chat_sidebar_row(old_chat.id, 13_000)
    update_chat_sidebar_row(new_chat.id, 14_000)

    assert {:ok, old_definition} =
             ImportDefinitions.create_definition(%{project_id: project.id, name: "Old Import"})

    assert {:ok, new_definition} =
             ImportDefinitions.create_definition(%{project_id: project.id, name: "New Import"})

    update_import_sidebar_row(old_definition.id, 15_000)
    update_import_sidebar_row(new_definition.id, 16_000)

    posts_view = Sidebar.view(project.id, "posts")
    assert titles_in_section(posts_view, "Drafts") == ["Draft New", "Draft Old"]
    assert titles_in_section(posts_view, "Published") == ["Published New", "Published Old"]
    assert titles_in_section(posts_view, "Archived") == ["Archived New", "Archived Old"]

    media_view = Sidebar.view(project.id, "media")
    assert Enum.map(media_view.items, & &1.title) == ["New Media", "Old Media"]

    scripts_view = Sidebar.view(project.id, "scripts")
    assert Enum.map(scripts_view.items, & &1.title) == ["New Script", "Old Script"]

    templates_view = Sidebar.view(project.id, "templates")
    assert Enum.map(templates_view.items, & &1.title) == ["New Template", "Old Template"]

    chat_view = Sidebar.view(project.id, "chat")
    assert Enum.map(chat_view.items, & &1.title) == ["New Chat", "Old Chat"]

    import_view = Sidebar.view(project.id, "import")
    assert Enum.map(import_view.items, & &1.title) == ["New Import", "Old Import"]
  end

  defp titles_in_section(view, title) do
    view.sections
    |> Enum.find(&(&1.title == title))
    |> Map.fetch!(:items)
    |> Enum.map(& &1.title)
  end

  defp update_post_sidebar_row(post_id, updates) do
    Repo.update_all(from(post in Post, where: post.id == ^post_id), set: updates)
  end

  defp update_media_sidebar_row(media_id, updates) do
    Repo.update_all(from(media in BDS.Media.Media, where: media.id == ^media_id), set: updates)
  end

  defp update_script_sidebar_row(script_id, updated_at) do
    Repo.update_all(from(script in BDS.Scripts.Script, where: script.id == ^script_id),
      set: [updated_at: updated_at]
    )
  end

  defp update_template_sidebar_row(template_id, updated_at) do
    Repo.update_all(from(template in BDS.Templates.Template, where: template.id == ^template_id),
      set: [updated_at: updated_at]
    )
  end

  defp update_chat_sidebar_row(conversation_id, updated_at) do
    Repo.update_all(
      from(conversation in BDS.AI.ChatConversation, where: conversation.id == ^conversation_id),
      set: [updated_at: updated_at]
    )
  end

  defp update_import_sidebar_row(definition_id, updated_at) do
    Repo.update_all(
      from(definition in BDS.ImportDefinitions.ImportDefinition,
        where: definition.id == ^definition_id
      ), set: [updated_at: updated_at])
  end
end
