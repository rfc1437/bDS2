defmodule BDS.Tags.Tag do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          project_id: String.t() | nil,
          name: String.t() | nil,
          color: String.t() | nil,
          post_template_slug: String.t() | nil,
          created_at: integer() | nil,
          updated_at: integer() | nil,
          project: term()
        }

  schema "tags" do
    field :name, :string
    field :color, :string
    field :post_template_slug, :string
    field :created_at, :integer
    field :updated_at, :integer

    belongs_to :project, BDS.Projects.Project, type: :string
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
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
