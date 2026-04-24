defmodule BDS.Tags.Tag do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "tags" do
    field :name, :string
    field :color, :string
    field :post_template_slug, :string
    field :created_at, :integer
    field :updated_at, :integer

    belongs_to :project, BDS.Projects.Project, type: :string
  end

  def changeset(tag, attrs) do
    tag
    |> cast(
      attrs,
      [:id, :project_id, :name, :color, :post_template_slug, :created_at, :updated_at],
      empty_values: [nil]
    )
    |> validate_required([:id, :project_id, :name, :created_at, :updated_at])
    |> assoc_constraint(:project)
  end
end
