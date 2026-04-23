defmodule BDS.TemplatesTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    {:ok, project} = BDS.Projects.create_project(%{name: "Templates"})
    %{project: project}
  end

  test "create_template creates a draft template with slug deduplication", %{project: project} do
    assert {:ok, template} =
             BDS.Templates.create_template(%{
               project_id: project.id,
               title: "Article View",
               kind: :post,
               content: "<article>{{ content }}</article>"
             })

    assert template.slug == "article-view"
    assert template.status == :draft
    assert template.enabled == true
    assert template.version == 1
    assert template.file_path == ""
    assert template.content == "<article>{{ content }}</article>"

    assert {:ok, duplicate} =
             BDS.Templates.create_template(%{project_id: project.id, title: "Article View", kind: :post, content: "x"})

    assert duplicate.slug == "article-view-2"
  end
end
