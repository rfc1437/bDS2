defmodule BDS.Posts.Link do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          source_post_id: String.t() | nil,
          target_post_id: String.t() | nil,
          source_post: term(),
          target_post: term(),
          link_text: String.t() | nil,
          created_at: integer() | nil
        }

  schema "post_links" do
    belongs_to :source_post, BDS.Posts.Post, foreign_key: :source_post_id, references: :id, type: :string
    belongs_to :target_post, BDS.Posts.Post, foreign_key: :target_post_id, references: :id, type: :string

    field :link_text, :string
    field :created_at, :integer
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:id, :source_post_id, :target_post_id, :link_text, :created_at])
    |> validate_required([:id, :source_post_id, :target_post_id, :created_at])
    |> foreign_key_constraint(:source_post_id)
    |> foreign_key_constraint(:target_post_id)
  end
end
