defmodule BDS.CSM013BangRenderingTest do
  use ExUnit.Case, async: false

  alias BDS.Rendering.PostRendering
  alias BDS.Rendering.TemplateSelection

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-csm013-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "CSM013", data_path: temp_dir})

    {:ok, _metadata} =
      BDS.Metadata.update_project_metadata(project.id, %{
        main_language: "en",
        blog_languages: ["en"]
      })

    %{project: project}
  end

  describe "template with syntax error" do
    test "render_template returns {:error, _} instead of raising", %{project: project} do
      bad_source = "{% for item in items %}unclosed"

      result = TemplateSelection.render_template(project.id, bad_source, %{})

      assert {:error, _reason} = result
    end

    test "publish_template rejects broken template source", %{project: project} do
      {:ok, template} =
        BDS.Templates.create_template(%{
          project_id: project.id,
          title: "Broken Template",
          kind: :post,
          content: "{% if true %}unclosed if"
        })

      assert {:error, {:invalid_liquid, _reason}} = BDS.Templates.publish_template(template.id)
    end
  end

  describe "Liquex.render! error in render_template" do
    test "returns {:error, _} when render raises on invalid AST usage", %{project: project} do
      source = "{% break %}"

      result = TemplateSelection.render_template(project.id, source, %{})

      assert {:error, _reason} = result
    end
  end

  describe "post_data_json_value" do
    test "returns valid JSON for normal post context" do
      context = %{
        id: "abc",
        title: "Test",
        slug: "test",
        excerpt: "An excerpt",
        author: "Author",
        language: "en",
        published_at: 1_000_000,
        created_at: 1_000_000,
        updated_at: 1_000_000,
        tags: ["a", "b"],
        categories: ["c"]
      }

      result = PostRendering.post_data_json_value(context)
      assert is_binary(result)
      assert {:ok, decoded} = Jason.decode(result)
      assert decoded["id"] == "abc"
      assert decoded["tags"] == ["a", "b"]
    end

    test "returns fallback JSON when context contains non-encodable data" do
      context = %{
        id: make_ref(),
        title: "Test",
        slug: "test",
        excerpt: nil,
        author: nil,
        language: "en",
        published_at: nil,
        created_at: nil,
        updated_at: nil,
        tags: [],
        categories: []
      }

      result = PostRendering.post_data_json_value(context)
      assert result == "{}"
    end
  end
end
