defmodule BDS.Projects.Project do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          data_path: String.t() | nil,
          created_at: integer() | nil,
          updated_at: integer() | nil,
          is_active: boolean(),
          posts: term()
        }

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :data_path, :string
    field :created_at, :integer
    field :updated_at, :integer
    field :is_active, :boolean, default: false

    has_many :posts, BDS.Posts.Post, foreign_key: :project_id
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(
      attrs,
      [:id, :name, :slug, :description, :data_path, :created_at, :updated_at, :is_active],
      empty_values: [nil]
    )
    |> validate_required([:id, :name, :slug, :created_at, :updated_at, :is_active])
    |> unique_constraint(:slug)
  end
end
