defmodule BDS.Desktop.ImportShellLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BDS.ImportDefinitions
  alias BDS.Projects

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    Enum.each(BDS.Tasks.list_running_tasks(), fn task ->
      BDS.Tasks.cancel_task(task.id)
    end)

    if :ets.whereis(:bds_ai_in_flight) != :undefined do
      Enum.each(:ets.tab2list(:bds_ai_in_flight), fn {_conversation_id, pid} ->
        Process.exit(pid, :kill)
      end)
    end

    for {_, pid, _, _} <- DynamicSupervisor.which_children(BDS.TCP.TaskSupervisor) do
      DynamicSupervisor.terminate_child(BDS.TCP.TaskSupervisor, pid)
    end

    for {_, pid, _, _} <- DynamicSupervisor.which_children(BDS.Tasks.TaskSupervisor) do
      DynamicSupervisor.terminate_child(BDS.Tasks.TaskSupervisor, pid)
    end

    Process.sleep(100)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-import-shell-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = Projects.create_project(%{name: "Import Shell", data_path: temp_dir})
    {:ok, _project} = Projects.set_active_project(project.id)

    %{project: project, temp_dir: temp_dir}
  end

  test "opening an import definition renders the dedicated import analysis editor instead of the fallback shell frame",
       %{project: project, temp_dir: temp_dir} do
    uploads_dir = Path.join(temp_dir, "uploads")
    wxr_path = Path.join(temp_dir, "legacy.xml")

    assert {:ok, definition} =
             ImportDefinitions.create_definition(%{
               project_id: project.id,
               name: "Legacy Import",
               wxr_file_path: wxr_path,
               uploads_folder_path: uploads_dir,
               last_analysis_result: Jason.encode!(cached_report(wxr_path, uploads_dir))
             })

    {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

    _html = render_click(view, "select_view", %{"view" => "import"})

    html =
      view
      |> element("[data-testid='sidebar-open-item'][data-item-id='#{definition.id}']")
      |> render_click()

    assert html =~ ~s(data-testid="import-editor")
    assert html =~ ~s(data-testid="import-editor-form")
    assert html =~ "Legacy Import"
    assert html =~ "Uploads Folder"
    assert html =~ "WXR File"
    assert html =~ "Ready to import:"
    assert html =~ "Import 5 Items"
    assert html =~ "Post Slug Conflicts"
    assert html =~ ~s(<option value="ignore" selected)
    assert html =~ ~s(<option value="overwrite")
    assert html =~ ~s(<option value="import")
    refute html =~ ~s(<option value="skip")
    refute html =~ ~s(<option value="merge")
    assert html =~ "Analyze with..."
    assert html =~ "Posts (2)"
    assert html =~ "Pages (1)"
    assert html =~ "Media (1)"
    assert html =~ "Click to add mapping"
    refute html =~ ~s(name="mapped_to")
    refute html =~ "Desktop workbench content routed through the Elixir shell."

    _html =
      view
      |> element("form:has(input[value='conflict-me'])")
      |> render_change(%{"resolution" => "overwrite"})

    updated_definition = ImportDefinitions.get_definition(definition.id)
    updated_report = ImportDefinitions.decode_analysis_result(updated_definition)

    assert [%{resolution: "overwrite"}] =
             Enum.filter(updated_report.details.posts, &(&1.slug == "conflict-me"))

    posts_html =
      view
      |> element("button[phx-value-section='posts']")
      |> render_click()

    assert posts_html =~ "Existing Match"
    assert posts_html =~ "WP Status"

    media_html =
      view
      |> element("button[phx-value-section='media']")
      |> render_click()

    assert media_html =~ "Filename"
    assert media_html =~ "Path"
  end

  defp cached_report(wxr_path, uploads_dir) do
    %{
      source_file: wxr_path,
      site_info: %{
        title: "Legacy Blog",
        url: "https://legacy.example",
        language: "en",
        source_file: wxr_path
      },
      post_stats: %{new_count: 1, update_count: 0, conflict_count: 1, duplicate_count: 0},
      page_stats: %{new_count: 1, update_count: 0, conflict_count: 0, duplicate_count: 0},
      media_stats: %{
        new_count: 1,
        update_count: 0,
        conflict_count: 0,
        duplicate_count: 0,
        missing_count: 0
      },
      category_stats: %{existing_count: 0, mapped_count: 0, new_count: 1},
      tag_stats: %{existing_count: 0, mapped_count: 0, new_count: 1},
      date_distribution: [%{year: 2024, post_count: 2, media_count: 1}],
      conflicts: [
        %{
          item_type: "post",
          item_name: "hello-world",
          resolution: "ignore",
          source_title: "Hello World",
          existing_title: "Existing Hello"
        }
      ],
      macros: %{
        total: 1,
        mapped_count: 0,
        unmapped_count: 1,
        discovered: [
          %{
            name: "gallery",
            mapped: false,
            total_count: 1,
            usages: [%{params: %{"ids" => "1,2"}, count: 1, validation_status: "unknown"}],
            post_slugs: ["hello-world"]
          }
        ]
      },
      items: %{
        posts: [
          %{item_type: "post", title: "Hello World", slug: "hello-world", status: "new"},
          %{
            item_type: "post",
            title: "Conflict Me",
            slug: "conflict-me",
            status: "conflict",
            resolution: "ignore"
          }
        ],
        pages: [
          %{item_type: "page", title: "About", slug: "about", status: "new"}
        ],
        media: [
          %{
            item_type: "media",
            title: "Import Asset",
            filename: "import-asset.txt",
            relative_path: "2024/05/import-asset.txt",
            source_file: Path.join(uploads_dir, "2024/05/import-asset.txt"),
            status: "new"
          }
        ],
        categories: [%{name: "General", exists_in_project: false, mapped_to: nil}],
        tags: [%{name: "News", exists_in_project: false, mapped_to: nil}]
      },
      details: %{
        posts: [
          %{
            item_type: "post",
            title: "Hello World",
            slug: "hello-world",
            status: "new",
            wp_status: "publish",
            author: "Importer",
            categories: ["General"],
            tags: ["News"],
            published_at: "2024-05-01 12:00:00",
            excerpt: "Legacy hello",
            content_markdown: "Hello world",
            content_preview: "Hello world"
          },
          %{
            item_type: "post",
            title: "Conflict Me",
            slug: "conflict-me",
            status: "conflict",
            resolution: "ignore",
            wp_status: "publish",
            author: "Importer",
            categories: ["General"],
            tags: ["News"],
            published_at: "2024-05-02 12:00:00",
            excerpt: "Legacy conflict",
            existing_title: "Existing Conflict",
            content_markdown: "Incoming conflict body",
            content_preview: "Incoming conflict body"
          }
        ],
        pages: [
          %{
            item_type: "page",
            title: "About",
            slug: "about",
            status: "new",
            wp_status: "publish",
            author: "Importer",
            categories: ["General"],
            tags: [],
            published_at: "2024-05-03 12:00:00",
            excerpt: "About page",
            content_markdown: "About page",
            content_preview: "About page"
          }
        ],
        media: [
          %{
            item_type: "media",
            title: "Import Asset",
            filename: "import-asset.txt",
            relative_path: "2024/05/import-asset.txt",
            source_file: Path.join(uploads_dir, "2024/05/import-asset.txt"),
            status: "new",
            mime_type: "text/plain",
            description: "Legacy text attachment",
            parent_wp_id: 101,
            created_at: "2024-05-03 12:00:00"
          }
        ]
      }
    }
  end
end
