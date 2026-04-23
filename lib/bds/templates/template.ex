defmodule BDS.Templates.Template do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "templates" do
    field :slug, :string
    field :title, :string
    field :kind, Ecto.Enum, values: [:post, :list, :not_found, :partial]
    field :enabled, :boolean, default: true
    field :version, :integer, default: 1
    field :file_path, :string, default: ""
    field :status, Ecto.Enum, values: [:draft, :published], default: :draft
    field :content, :string
    field :created_at, :integer
    field :updated_at, :integer

    belongs_to :project, BDS.Projects.Project, type: :string
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [:id, :project_id, :slug, :title, :kind, :enabled, :version, :file_path, :status, :content, :created_at, :updated_at],
      empty_values: [nil]
    )
    |> validate_required([:id, :project_id, :slug, :title, :kind, :enabled, :version, :status, :created_at, :updated_at])
    |> assoc_constraint(:project)
    |> unique_constraint(:slug, name: :templates_project_slug_idx)
  end
end
