defmodule BDS.Media.Translation do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          translation_for: String.t() | nil,
          media: term(),
          project_id: String.t() | nil,
          language: String.t() | nil,
          title: String.t() | nil,
          alt: String.t() | nil,
          caption: String.t() | nil,
          created_at: integer() | nil,
          updated_at: integer() | nil
        }

  schema "media_translations" do
    belongs_to :media, BDS.Media.Media,
      foreign_key: :translation_for,
      references: :id,
      type: :string

    field :project_id, :string
    field :language, :string
    field :title, :string
    field :alt, :string
    field :caption, :string
    field :created_at, :integer
    field :updated_at, :integer
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
        :alt,
        :caption,
        :created_at,
        :updated_at
      ],
      empty_values: [nil]
    )
    |> validate_required([
      :id,
      :project_id,
      :translation_for,
      :language,
      :created_at,
      :updated_at
    ])
    |> foreign_key_constraint(:translation_for)
    |> unique_constraint(:language, name: :media_translations_translation_for_language_index)
  end
end
