defmodule BDS.Posts.Post do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias BDS.Types.StringList

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @statuses [:draft, :published, :archived]

  schema "posts" do
    belongs_to :project, BDS.Projects.Project, type: :string

    field :title, :string
    field :slug, :string
    field :excerpt, :string
    field :content, :string
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :author, :string
    field :created_at, :integer
    field :updated_at, :integer
    field :published_at, :integer
    field :file_path, :string, default: ""
    field :checksum, :string
    field :tags, StringList, default: []
    field :categories, StringList, default: []
    field :template_slug, :string
    field :language, :string
    field :do_not_translate, :boolean, default: false
    field :published_title, :string
    field :published_content, :string
    field :published_tags, :string
    field :published_categories, :string
    field :published_excerpt, :string
  end

  def changeset(post, attrs) do
    post
    |> cast(
      attrs,
      [
        :id,
        :project_id,
        :title,
        :slug,
        :excerpt,
        :content,
        :status,
        :author,
        :created_at,
        :updated_at,
        :published_at,
        :file_path,
        :checksum,
        :tags,
        :categories,
        :template_slug,
        :language,
        :do_not_translate,
        :published_title,
        :published_content,
        :published_tags,
        :published_categories,
        :published_excerpt
      ],
      empty_values: [nil]
    )
    |> validate_required([:id, :project_id, :slug, :status, :created_at, :updated_at, :do_not_translate])
    |> assoc_constraint(:project)
    |> unique_constraint(:slug, name: :posts_project_slug_idx)
  end
end
