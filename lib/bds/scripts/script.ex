defmodule BDS.Scripts.Script do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t(),
          project_id: String.t(),
          slug: String.t() | nil,
          title: String.t() | nil,
          kind: :macro | :utility | :transform | nil,
          entrypoint: String.t() | nil,
          enabled: boolean() | nil,
          version: integer() | nil,
          file_path: String.t() | nil,
          status: :draft | :published | nil,
          content: String.t() | nil,
          created_at: integer() | nil,
          updated_at: integer() | nil,
          project: term()
        }

  schema "scripts" do
    field :slug, :string
    field :title, :string
    field :kind, Ecto.Enum, values: [:macro, :utility, :transform]
    field :entrypoint, :string
    field :enabled, :boolean, default: true
    field :version, :integer, default: 1
    field :file_path, :string, default: ""
    field :status, Ecto.Enum, values: [:draft, :published], default: :draft
    field :content, :string
    field :created_at, :integer
    field :updated_at, :integer

    belongs_to :project, BDS.Projects.Project, type: :string
  end

  def changeset(script, attrs) do
    script
    |> cast(
      attrs,
      [
        :id,
        :project_id,
        :slug,
        :title,
        :kind,
        :entrypoint,
        :enabled,
        :version,
        :file_path,
        :status,
        :content,
        :created_at,
        :updated_at
      ],
      empty_values: [nil]
    )
    |> validate_required([
      :id,
      :project_id,
      :slug,
      :title,
      :kind,
      :entrypoint,
      :enabled,
      :version,
      :status,
      :created_at,
      :updated_at
    ])
    |> assoc_constraint(:project)
    |> unique_constraint(:slug, name: :scripts_project_slug_idx)
  end
end
