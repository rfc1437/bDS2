defmodule BDS.Embeddings.Key do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:label, :integer, autogenerate: false}
  @foreign_key_type :string

  schema "embedding_keys" do
    belongs_to :post, BDS.Posts.Post, type: :string
    belongs_to :project, BDS.Projects.Project, type: :string

    field :content_hash, :string
    # Packed little-endian Float32 BLOB (dimensions * 4 bytes), per the
    # VectorCacheInDb invariant in specs/embedding.allium.
    field :vector, :binary
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:label, :post_id, :project_id, :content_hash, :vector])
    |> validate_required([:label, :post_id, :project_id, :content_hash, :vector])
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:project_id)
  end
end
