defmodule BDS.UI.PostEditorTest do
  use ExUnit.Case, async: false

  alias BDS.UI.PostEditor.{Draft, Metadata, Persistence}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir = Path.join(System.tmp_dir!(), "bds-ui-pe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "UI PostEditor", data_path: temp_dir})

    {:ok, post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "First Post",
        content: "hello world",
        tags: ["elixir"],
        language: "en"
      })

    %{project: project, post: post}
  end

  test "persisted_form builds the canonical draft", %{post: post} do
    metadata = Metadata.project_metadata(post.project_id)
    form = Draft.persisted_form(post, metadata, "en")

    assert form["title"] == "First Post"
    assert form["content"] == "hello world"
    assert form["tags"] == "elixir"
    assert form["language"] == "en"
  end

  test "persist saves an edited draft and publish publishes it", %{post: post} do
    metadata = Metadata.project_metadata(post.project_id)
    form = Draft.persisted_form(post, metadata, "en")

    draft = %{form | "title" => "Renamed Post", "content" => "updated body"}

    assert {:ok, saved} = Persistence.persist(post, draft, "en", metadata, :save)
    assert saved.title == "Renamed Post"
    assert saved.status == :draft

    form = Draft.persisted_form(saved, metadata, "en")
    assert {:ok, published} = Persistence.persist(saved, form, "en", metadata, :publish)
    assert published.status == :published
    assert published.file_path != ""
  end

  test "discard on an unpublished draft is a no-op success", %{post: post} do
    metadata = Metadata.project_metadata(post.project_id)
    assert {:ok, _post} = Persistence.discard(post, "en", metadata)
  end

  test "normalize_params keeps the active language on same-language edits" do
    params = %{"title" => "T", "language" => "DE "}

    assert Draft.normalize_params(params, "de", "de")["language"] == "de"
    assert Draft.normalize_params(params, "de", "fr")["language"] == "fr"
  end
end
