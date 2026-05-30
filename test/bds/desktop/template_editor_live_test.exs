defmodule BDS.Desktop.TemplateEditorLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Templates

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
      Path.join(
        System.tmp_dir!(),
        "bds-template-editor-live-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(temp_dir)

    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = Projects.create_project(%{name: "Template Editor", data_path: temp_dir})
    {:ok, _project} = Projects.set_active_project(project.id)

    %{project: project, temp_dir: temp_dir}
  end

  defp open_template(view, template_id) do
    view
    |> element("[data-testid='sidebar-open-item'][data-item-id='#{template_id}']")
    |> render_click()
  end

  describe "TemplateEditor save" do
    test "save with valid Liquid content persists changes and bumps version",
         %{project: project} do
      assert {:ok, template} =
               Templates.create_template(%{
                 project_id: project.id,
                 title: "My Template",
                 kind: :post,
                 content: "{{ content }}"
               })

      assert template.version == 1

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      _html = render_click(view, "select_view", %{"view" => "templates"})
      html = open_template(view, template.id)

      assert html =~ "templates-view-shell"

      view
      |> element("[data-testid='template-editor'] .templates-save-button")
      |> render_click()

      reloaded = Templates.get_template(template.id)
      assert reloaded.version == 2
    end

    test "save with invalid Liquid content is rejected (version unchanged)",
         %{project: project} do
      assert {:ok, template} =
               Templates.create_template(%{
                 project_id: project.id,
                 title: "Bad Template",
                 kind: :post,
                 content: "{% invalid_tag_xyz %}"
               })

      assert template.version == 1

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      _html = render_click(view, "select_view", %{"view" => "templates"})
      html = open_template(view, template.id)

      assert html =~ "templates-view-shell"

      view
      |> element("[data-testid='template-editor'] .templates-save-button")
      |> render_click()

      reloaded = Templates.get_template(template.id)
      assert reloaded.version == 1
    end
  end

  describe "TemplateEditor validate" do
    test "validate runs without side effects (version unchanged)", %{project: project} do
      assert {:ok, template} =
               Templates.create_template(%{
                 project_id: project.id,
                 title: "Validate Template",
                 kind: :post,
                 content: "{{ content }}"
               })

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      _html = render_click(view, "select_view", %{"view" => "templates"})
      html = open_template(view, template.id)

      assert html =~ "templates-view-shell"

      view
      |> element("[data-testid='template-editor'] .templates-validate-button")
      |> render_click()

      reloaded = Templates.get_template(template.id)
      assert reloaded.version == 1
      assert reloaded.content == "{{ content }}"
    end
  end

  describe "TemplateEditor delete" do
    test "delete removes template from DB", %{project: project} do
      assert {:ok, template} =
               Templates.create_template(%{
                 project_id: project.id,
                 title: "Delete Template",
                 kind: :post,
                 content: "{{ content }}"
               })

      assert {:ok, _published} = Templates.publish_template(template.id)

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      _html = render_click(view, "select_view", %{"view" => "templates"})
      html = open_template(view, template.id)

      assert html =~ "templates-view-shell"

      view
      |> element("[data-testid='template-editor'] .danger")
      |> render_click()

      refute Repo.get(BDS.Templates.Template, template.id)
    end

    test "delete with references clears them (force delete), removes template",
         %{project: project} do
      assert {:ok, template} =
               Templates.create_template(%{
                 project_id: project.id,
                 title: "Referenced Template",
                 kind: :post,
                 content: "{{ content }}"
               })

      assert {:ok, published} = Templates.publish_template(template.id)

      assert {:ok, post} =
               Posts.create_post(%{
                 project_id: project.id,
                 title: "Ref Post",
                 content: "Body",
                 template_slug: published.slug
               })

      assert {:ok, _published_post} = Posts.publish_post(post.id)

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      _html = render_click(view, "select_view", %{"view" => "templates"})
      html = open_template(view, template.id)

      assert html =~ "templates-view-shell"

      view
      |> element("[data-testid='template-editor'] .danger")
      |> render_click()

      refute Repo.get(BDS.Templates.Template, template.id)

      reloaded_post = Repo.get(Post, post.id)
      assert reloaded_post.template_slug == nil
    end

    test "delete removes the .liquid file from disk", %{project: project, temp_dir: temp_dir} do
      assert {:ok, template} =
               Templates.create_template(%{
                 project_id: project.id,
                 title: "File Template",
                 kind: :post,
                 content: "{{ content }}"
               })

      assert {:ok, published} = Templates.publish_template(template.id)

      file_path = Path.join(temp_dir, published.file_path)
      assert File.exists?(file_path)

      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      _html = render_click(view, "select_view", %{"view" => "templates"})
      html = open_template(view, template.id)

      assert html =~ "templates-view-shell"

      view
      |> element("[data-testid='template-editor'] .danger")
      |> render_click()

      refute File.exists?(file_path)
    end
  end
end
