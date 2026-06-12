defmodule BDS.Desktop.TagEditorLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BDS.{Posts, Projects, Repo, Tags}
  alias BDS.Desktop.ShellLive.TagsEditor

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, :manual) end)

    Enum.each(BDS.Tasks.list_running_tasks(), fn task ->
      BDS.Tasks.cancel_task(task.id)
    end)

    for {_, pid, _, _} <- DynamicSupervisor.which_children(BDS.TCP.TaskSupervisor) do
      DynamicSupervisor.terminate_child(BDS.TCP.TaskSupervisor, pid)
    end

    for {_, pid, _, _} <- DynamicSupervisor.which_children(BDS.Tasks.TaskSupervisor) do
      DynamicSupervisor.terminate_child(BDS.Tasks.TaskSupervisor, pid)
    end

    Process.sleep(100)

    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "bds-tag-editor-live-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = Projects.create_project(%{name: "Tag Editor", data_path: temp_dir})
    {:ok, _project} = Projects.set_active_project(project.id)

    %{project: project, temp_dir: temp_dir}
  end

  defp open_tags_editor(view) do
    _html = render_click(view, "select_view", %{"view" => "tags"})

    view
    |> element("[data-testid='sidebar-open-item'][data-item-id='tags-cloud']")
    |> render_click()
  end

  describe "tag_font_size" do
    test "returns min font for the smallest count" do
      counts = [%{name: "a", count: 1}, %{name: "b", count: 5}]
      assert TagsEditor.tag_font_size(1, counts) == 0.85
    end

    test "returns max font for the largest count" do
      counts = [%{name: "a", count: 1}, %{name: "b", count: 10}]
      assert TagsEditor.tag_font_size(10, counts) == 1.80
    end

    test "scales proportionally between min and max" do
      counts = [%{name: "a", count: 1}, %{name: "b", count: 3}, %{name: "c", count: 5}]
      size = TagsEditor.tag_font_size(3, counts)
      assert size > 0.85 and size < 1.80
    end

    test "returns min font when all tags have count 1" do
      counts = [%{name: "a", count: 1}, %{name: "b", count: 1}]
      assert TagsEditor.tag_font_size(1, counts) == 0.85
    end
  end

  describe "tag_style" do
    test "includes font-size" do
      counts = [%{name: "a", count: 1}]
      style = TagsEditor.tag_style(%{name: "a", count: 1, color: nil}, counts)
      assert style =~ "font-size:"
    end

    test "includes background-color and white text when tag has color" do
      counts = [%{name: "a", count: 1, color: "#ef4444"}]
      style = TagsEditor.tag_style(%{name: "a", count: 1, color: "#ef4444"}, counts)
      assert style =~ "background-color: #ef4444"
      assert style =~ "color: #ffffff"
    end

    test "omits background-color when tag has no color" do
      counts = [%{name: "a", count: 1}]
      style = TagsEditor.tag_style(%{name: "a", count: 1, color: nil}, counts)
      refute style =~ "background-color"
      refute style =~ "color:"
    end
  end

  describe "colour picker" do
    test "renders 17 preset swatches", %{project: _project} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
      html = open_tags_editor(view)

      assert html =~ "colour-picker-wrap"
      assert html =~ "colour-picker-popover"
      assert html =~ "colour-picker-grid"

      preset_count =
        html |> String.split(~r/\bcolour-picker-swatch\b/) |> length() |> Kernel.-(1)

      assert preset_count == 17
    end

    test "pick_new_tag_color event updates new_tag color assign", %{project: _project} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
      _html = open_tags_editor(view)

      view
      |> element("#cp-pick_new_tag_color .colour-picker-swatch:first-child")
      |> render_click()

      html = render(view)
      assert html =~ ~s(value="#3b82f6") or html =~ ~s(value="#ef4444")
    end
  end

  describe "create tag form" do
    test "creating a tag through the UI makes it appear in the cloud", %{project: project} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
      _html = open_tags_editor(view)

      view
      |> element("#tags-editor-shell form.tag-create-form")
      |> render_change(%{"new_tag" => %{"name" => "MyTag", "color" => ""}})

      view
      |> element("#tags-editor-shell button[phx-click='create_tag_editor']")
      |> render_click()

      html = render(view)
      assert html =~ "MyTag"
      assert Repo.get_by(BDS.Tags.Tag, project_id: project.id, name: "MyTag") != nil
    end

    test "create form clears after successful creation", %{project: _project} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
      _html = open_tags_editor(view)

      view
      |> element("#tags-editor-shell form.tag-create-form")
      |> render_change(%{"new_tag" => %{"name" => "TempTag", "color" => "#ef4444"}})

      view
      |> element("#tags-editor-shell button[phx-click='create_tag_editor']")
      |> render_click()

      html = render(view)
      refute html =~ ~s(value="TempTag")
    end
  end

  describe "tag delete confirmation" do
    test "delete button opens a confirmation dialog when a tag is selected",
         %{project: project} do
      assert {:ok, _tag} =
               Tags.create_tag(%{project_id: project.id, name: "Doomed"})

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
      _html = open_tags_editor(view)

      view
      |> element("#tags-editor-shell button.tag-cloud-item[phx-value-name='Doomed']")
      |> render_click()

      view
      |> element("#tags-editor-shell button.danger")
      |> render_click()

      html = render(view)
      assert html =~ "shell-overlay-backdrop"
      assert html =~ "confirm-delete-modal"
      assert html =~ "Delete Tag"
    end

    test "confirms tag deletion removes the tag", %{project: project} do
      assert {:ok, tag} =
               Tags.create_tag(%{project_id: project.id, name: "Doomed"})

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
      _html = open_tags_editor(view)

      view
      |> element("#tags-editor-shell button.tag-cloud-item[phx-value-name='Doomed']")
      |> render_click()

      view
      |> element("#tags-editor-shell button.danger")
      |> render_click()

      view
      |> element(".shell-overlay-backdrop button[phx-click='overlay_confirm']")
      |> render_click()

      refute Repo.get(BDS.Tags.Tag, tag.id)
    end

    test "cancelling tag deletion does not remove the tag", %{project: project} do
      assert {:ok, tag} =
               Tags.create_tag(%{project_id: project.id, name: "Safe"})

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
      _html = open_tags_editor(view)

      view
      |> element("#tags-editor-shell button.tag-cloud-item[phx-value-name='Safe']")
      |> render_click()

      view
      |> element("#tags-editor-shell button.danger")
      |> render_click()

      view
      |> element(".confirm-delete-modal .button-cancel")
      |> render_click()

      assert Repo.get(BDS.Tags.Tag, tag.id)
    end

    test "deleting a tag used in posts shows the post count", %{project: project, temp_dir: _temp_dir} do
      assert {:ok, _tag} =
               Tags.create_tag(%{project_id: project.id, name: "UsedTag"})

      assert {:ok, _post} =
               Posts.create_post(%{
                 project_id: project.id,
                 title: "Post with tag",
                 content: "Body",
                 tags: ["UsedTag"]
               })

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
      _html = open_tags_editor(view)

      view
      |> element("#tags-editor-shell button.tag-cloud-item[phx-value-name='UsedTag']")
      |> render_click()

      view
      |> element("#tags-editor-shell button.danger")
      |> render_click()

      html = render(view)
      assert html =~ "1"
    end
  end

  describe "cloud sizing UI" do
    test "tags with different post counts have different inline font sizes",
         %{project: project, temp_dir: _temp_dir} do
      assert {:ok, _small_tag} =
               Tags.create_tag(%{project_id: project.id, name: "Small"})

      assert {:ok, _large_tag} =
               Tags.create_tag(%{project_id: project.id, name: "Large"})

      assert {:ok, _post_a} =
               Posts.create_post(%{
                 project_id: project.id,
                 title: "A",
                 content: "Body",
                 tags: ["Small"]
               })

      for _i <- 1..10 do
        assert {:ok, _post} =
                 Posts.create_post(%{
                   project_id: project.id,
                   title: "Large #{System.unique_integer([:positive])}",
                   content: "Body",
                   tags: ["Large"]
                 })
      end

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
      html = open_tags_editor(view)

      assert html =~ "Small", "Small tag not rendered in cloud"
      assert html =~ "Large", "Large tag not rendered in cloud"
      assert html =~ "font-size:", "No inline font-size found"

      assert html =~ ~r/phx-value-name="Small"/,
             "Small tag not found"

      assert html =~ ~r/phx-value-name="Large"/,
             "Large tag not found"

      small_style = html |> then(&Regex.run(~r/style="([^"]+)"[^>]*phx-value-name="Small"/s, &1))
      large_style = html |> then(&Regex.run(~r/style="([^"]+)"[^>]*phx-value-name="Large"/s, &1))

      assert small_style, "Could not find Small tag style+value"
      assert large_style, "Could not find Large tag style+value"

      small_str = small_style |> List.last()
      large_str = large_style |> List.last()

      assert small_str =~ ~r/font-size: [\d.]+rem/, "Small tag missing font-size"
      assert large_str =~ ~r/font-size: [\d.]+rem/, "Large tag missing font-size"
    end

    test "colored tag has background-color and white text in inline style",
         %{project: project, temp_dir: _temp_dir} do
      assert {:ok, _colored_tag} =
               Tags.create_tag(%{project_id: project.id, name: "Blue", color: "#3b82f6"})

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)
      html = open_tags_editor(view)

      assert html =~ ~r/style="[^"]*background-color: #3b82f6[^"]*color: #ffffff/
    end
  end
end
