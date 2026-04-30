defmodule BDS.Posts.PostMedia do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          project_id: String.t() | nil,
          post_id: String.t() | nil,
          media_id: String.t() | nil,
          post: term(),
          media: term(),
          sort_order: integer() | nil,
          created_at: integer() | nil
        }

  schema "post_media" do
    field :project_id, :string

    belongs_to :post, BDS.Posts.Post, foreign_key: :post_id, references: :id, type: :string
    belongs_to :media, BDS.Media.Media, foreign_key: :media_id, references: :id, type: :string

    field :sort_order, :integer, default: 0
    field :created_at, :integer
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(post_media, attrs) do
    post_media
    |> cast(attrs, [:id, :project_id, :post_id, :media_id, :sort_order, :created_at])
    |> validate_required([:id, :project_id, :post_id, :media_id, :sort_order, :created_at])
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:media_id)
    |> unique_constraint([:post_id, :media_id], name: :post_media_post_media_idx)
  end
end
