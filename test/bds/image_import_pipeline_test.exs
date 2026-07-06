defmodule BDS.ImageImportPipelineTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BDS.Desktop.{FilePicker, Overlay}
  alias BDS.{Metadata, AI, Repo}

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-image-import-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} =
      BDS.Projects.create_project(%{name: "Image Import Test", data_path: temp_dir})

    %{project: project, temp_dir: temp_dir}
  end

  # ── FilePicker multi-select parsing ────────────────────────────────────────

  describe "FilePicker.choose_files/2" do
    test "single selection returns a single-item list" do
      # Simulate what osascript returns for regular choose file
      result = FilePicker.parse_choose_files_result("/Users/test/image.png", false)
      assert result == {:ok, "/Users/test/image.png"}
    end

    test "multi selection parses newline-separated paths" do
      result =
        FilePicker.parse_choose_files_result(
          "/Users/test/photo1.jpg\n/Users/test/photo2.png\n/Users/test/photo3.heic",
          true
        )

      assert result ==
               {:ok,
                ["/Users/test/photo1.jpg", "/Users/test/photo2.png", "/Users/test/photo3.heic"]}
    end

    test "multi selection filters out empty lines" do
      result =
        FilePicker.parse_choose_files_result(
          "/Users/test/photo1.jpg\n\n/Users/test/photo2.png\n  \n/Users/test/photo3.heic\n",
          true
        )

      assert result ==
               {:ok,
                ["/Users/test/photo1.jpg", "/Users/test/photo2.png", "/Users/test/photo3.heic"]}
    end

    test "multi selection with single file returns list with one element" do
      result = FilePicker.parse_choose_files_result("/Users/test/photo1.jpg", true)
      assert result == {:ok, ["/Users/test/photo1.jpg"]}
    end
  end

  # ── Metadata image_import_concurrency ───────────────────────────────────────

  describe "Metadata image_import_concurrency" do
    test "defaults to 4 for new projects", %{project: project} do
      {:ok, metadata} = Metadata.get_project_metadata(project.id)
      assert metadata.image_import_concurrency == 4
    end

    test "clamps to minimum 1", %{project: project} do
      {:ok, _metadata} =
        Metadata.update_project_metadata(project.id, %{image_import_concurrency: 0})

      {:ok, metadata} = Metadata.get_project_metadata(project.id)
      assert metadata.image_import_concurrency == 1
    end

    test "clamps to maximum 8", %{project: project} do
      {:ok, _metadata} =
        Metadata.update_project_metadata(project.id, %{image_import_concurrency: 100})

      {:ok, metadata} = Metadata.get_project_metadata(project.id)
      assert metadata.image_import_concurrency == 8
    end

    test "persists and reads correctly", %{project: project} do
      {:ok, _metadata} =
        Metadata.update_project_metadata(project.id, %{image_import_concurrency: 3})

      {:ok, metadata} = Metadata.get_project_metadata(project.id)
      assert metadata.image_import_concurrency == 3
    end

    test "handles string input", %{project: project} do
      {:ok, _metadata} =
        Metadata.update_project_metadata(project.id, %{image_import_concurrency: "5"})

      {:ok, metadata} = Metadata.get_project_metadata(project.id)
      assert metadata.image_import_concurrency == 5
    end

    test "handles nil as default", %{project: project} do
      {:ok, _metadata} =
        Metadata.update_project_metadata(project.id, %{image_import_concurrency: nil})

      {:ok, metadata} = Metadata.get_project_metadata(project.id)
      assert metadata.image_import_concurrency == 4
    end

    test "reflects in form as string", %{project: project} do
      {:ok, metadata} = Metadata.get_project_metadata(project.id)

      form =
        BDS.Desktop.ShellLive.SettingsEditor.ProjectSettings.project_form(metadata)

      assert form["image_import_concurrency"] == "4"
    end
  end

  # ── Overlay struct post_id ────────────────────────────────────────────────

  describe "Overlay insert_media" do
    test "open(:post, :insert_media, context) includes post_id" do
      context = %{
        current_tab: %{
          type: :post,
          id: "post-uuid-123",
          title: "Test Post",
          subtitle: "draft"
        },
        media: [],
        insert_media_title: "Insert Media"
      }

      overlay = Overlay.open(:post, :insert_media, context)
      assert overlay.post_id == "post-uuid-123"
    end

    test "post_id is nil when opened from non-post context" do
      context = %{
        current_tab: %{
          type: :media,
          id: "media-uuid-456",
          title: "Test Media",
          subtitle: "image/png"
        },
        media: [],
        insert_media_title: "Insert Media"
      }

      overlay = Overlay.open(:media, :insert_media, context)
      assert overlay == nil
    end

    test "set_search_query preserves post_id" do
      overlay = %{
        kind: :insert_media,
        title: "Insert Media",
        search_query: "",
        results: [],
        all_media: [],
        post_id: "post-uuid-789"
      }

      result = Overlay.set_search_query(overlay, "search term")
      assert result.post_id == "post-uuid-789"
    end
  end

  # ── Airplane mode gating via shell_live event ─────────────────────────────

  describe "overlay_add_images airplane mode gating" do
    setup do
      prev_auto = System.get_env("BDS_DESKTOP_AUTOMATION")
      System.put_env("BDS_DESKTOP_AUTOMATION", "1")

      on_exit(fn ->
        if prev_auto,
          do: System.put_env("BDS_DESKTOP_AUTOMATION", prev_auto),
          else: System.delete_env("BDS_DESKTOP_AUTOMATION")
      end)
    end

    test "shows toast in airplane mode when Add Gallery Images is clicked", %{project: project} do
      {:ok, _project} = BDS.Projects.set_active_project(project.id)

      assert :ok = AI.set_airplane_mode(true)

      {:ok, post} =
        BDS.Posts.create_post(%{
          project_id: project.id,
          title: "Gallery Post",
          content: "Content"
        })

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => post.id,
        "title" => post.title,
        "subtitle" => "draft"
      })

      view
      |> element("[phx-click='add_gallery_images']")
      |> render_click()

      output_html = render_click(view, "select_panel_tab", %{"tab" => "output"})
      assert output_html =~ "Automatic AI actions stay gated by airplane mode"

      assert :ok = AI.set_airplane_mode(false)
    end
  end
end
