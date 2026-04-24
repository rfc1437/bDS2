defmodule BDS.Media.Media do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias BDS.Types.StringList

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "media" do
    belongs_to :project, BDS.Projects.Project, type: :string

    field :filename, :string
    field :original_name, :string
    field :mime_type, :string
    field :size, :integer
    field :width, :integer
    field :height, :integer
    field :title, :string
    field :alt, :string
    field :caption, :string
    field :author, :string
    field :language, :string
    field :file_path, :string
    field :sidecar_path, :string
    field :checksum, :string
    field :tags, StringList, default: []
    field :created_at, :integer
    field :updated_at, :integer
  end

  def changeset(media, attrs) do
    media
    |> cast(
      attrs,
      [
        :id,
        :project_id,
        :filename,
        :original_name,
        :mime_type,
        :size,
        :width,
        :height,
        :title,
        :alt,
        :caption,
        :author,
        :language,
        :file_path,
        :sidecar_path,
        :checksum,
        :tags,
        :created_at,
        :updated_at
      ],
      empty_values: [nil]
    )
    |> validate_required([
      :id,
      :project_id,
      :filename,
      :original_name,
      :mime_type,
      :size,
      :file_path,
      :sidecar_path,
      :created_at,
      :updated_at
    ])
    |> assoc_constraint(:project)
  end
end
