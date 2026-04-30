defmodule BDS.Posts.Translation do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @statuses [:draft, :published]

  @type status :: :draft | :published

  @type t :: %__MODULE__{
          id: String.t() | nil,
          translation_for: String.t() | nil,
          post: term(),
          project_id: String.t() | nil,
          language: String.t() | nil,
          title: String.t() | nil,
          excerpt: String.t() | nil,
          content: String.t() | nil,
          status: status(),
          created_at: integer() | nil,
          updated_at: integer() | nil,
          published_at: integer() | nil,
          file_path: String.t(),
          checksum: String.t() | nil
        }

  schema "post_translations" do
    belongs_to :post, BDS.Posts.Post,
      foreign_key: :translation_for,
      references: :id,
      type: :string

    field :project_id, :string
    field :language, :string
    field :title, :string
    field :excerpt, :string
    field :content, :string
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :created_at, :integer
    field :updated_at, :integer
    field :published_at, :integer
    field :file_path, :string, default: ""
    field :checksum, :string
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(translation, attrs) do
    translation
    |> cast(
      attrs,
      [
        :id,
        :project_id,
        :translation_for,
        :language,
        :title,
        :excerpt,
        :content,
        :status,
        :created_at,
        :updated_at,
        :published_at,
        :file_path,
        :checksum
      ],
      empty_values: [nil]
    )
    |> validate_required([
      :id,
      :project_id,
      :translation_for,
      :language,
      :title,
      :status,
      :created_at,
      :updated_at
    ])
    |> foreign_key_constraint(:translation_for)
    |> unique_constraint(:language, name: :post_translations_translation_language_idx)
  end
end
