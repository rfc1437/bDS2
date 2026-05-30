defmodule BDS.EditorImageDropTest do
  @moduledoc """
  Covers the drag-and-drop image chain (action_patterns.allium
  DragDropImageChain / editor_post.allium PostDragDropImage):

    1. import media (file copy + base sidecar)
    2. generate thumbnails synchronously
    3. link media to the post
    4. insert `![](bds-media://id)` at the cursor

  Steps 5-6 (AI analysis + auto-translate) are background AI activities gated
  behind airplane mode and are not exercised here.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BDS.Desktop.ShellLive.EditorImageDrop
  alias BDS.{AI, Media, Repo}

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-editor-drop-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Drop Test", data_path: temp_dir})
    {:ok, _project} = BDS.Projects.set_active_project(project.id)

    {:ok, post} =
      BDS.Posts.create_post(%{project_id: project.id, title: "Drop Post", content: "Body"})

    %{project: project, post: post, temp_dir: temp_dir}
  end

  defp write_image!(path) do
    File.write!(path, Image.new!(4, 4, color: [255, 0, 0]) |> Image.write!(:memory, suffix: ".jpg"))
    path
  end

  describe "EditorImageDrop.import_and_link/3" do
    test "imports, generates thumbnails, links the post, and returns image markdown", %{
      project: project,
      post: post,
      temp_dir: temp_dir
    } do
      source = write_image!(Path.join(temp_dir, "dropped.jpg"))

      assert {:ok, media, markdown} =
               EditorImageDrop.import_and_link(project.id, post.id, source)

      # Step 1: media row + file copy.
      assert Repo.get(Media.Media, media.id)
      assert File.exists?(Path.join(temp_dir, media.file_path))

      # Step 2: thumbnails generated synchronously.
      thumbnails = Media.thumbnail_paths(media)
      assert thumbnails != %{}

      Enum.each(Map.values(thumbnails), fn path ->
        assert File.exists?(Path.join(temp_dir, path)), "missing thumbnail #{path}"
      end)

      # Step 3: linked to the post.
      assert [linked] = Media.list_linked_posts(media.id)
      assert linked.post_id == post.id

      # Step 4: markdown reference inserted at the cursor.
      assert markdown == "![](bds-media://#{media.id})"
    end

    test "non-image files yield a plain link reference", %{
      project: project,
      post: post,
      temp_dir: temp_dir
    } do
      source = Path.join(temp_dir, "notes.txt")
      File.write!(source, "plain text")

      assert {:ok, media, markdown} =
               EditorImageDrop.import_and_link(project.id, post.id, source)

      assert markdown == "[#{media.original_name}](bds-media://#{media.id})"
    end
  end

  describe "drag-drop event in the post editor" do
    setup do
      prev = System.get_env("BDS_DESKTOP_AUTOMATION")
      System.put_env("BDS_DESKTOP_AUTOMATION", "1")

      on_exit(fn ->
        if prev,
          do: System.put_env("BDS_DESKTOP_AUTOMATION", prev),
          else: System.delete_env("BDS_DESKTOP_AUTOMATION")
      end)

      :ok
    end

    test "dropping an image imports, links, and inserts markdown at the cursor", %{
      post: post,
      temp_dir: temp_dir
    } do
      source = write_image!(Path.join(temp_dir, "editor-drop.jpg"))

      # Airplane mode keeps the background AI steps (5-6) out of the test while
      # the synchronous chain (1-4) must still complete.
      :ok = AI.set_airplane_mode(true)

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      render_click(view, "pin_sidebar_item", %{
        "route" => "post",
        "id" => post.id,
        "title" => post.title,
        "subtitle" => "draft"
      })

      view
      |> element("[data-monaco-drop-event='editor_image_dropped']")
      |> render_hook("editor_image_dropped", %{"path" => source})

      assert_push_event(view, "post-editor-insert-content", %{content: content})
      assert content =~ ~r{^!\[\]\(bds-media://[0-9a-f-]+\)$}

      [media] = Repo.all(Media.Media)
      assert media.project_id == post.project_id
      assert content == "![](bds-media://#{media.id})"

      assert [linked] = Media.list_linked_posts(media.id)
      assert linked.post_id == post.id

      # Synchronous steps ran despite airplane mode; no AI metadata applied.
      assert is_nil(media.title)

      :ok = AI.set_airplane_mode(false)
    end
  end
end
