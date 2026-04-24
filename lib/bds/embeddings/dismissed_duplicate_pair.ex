defmodule BDS.Embeddings.DismissedDuplicatePair do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "dismissed_duplicate_pairs" do
    belongs_to :project, BDS.Projects.Project, type: :string
    field :post_id_a, :string
    field :post_id_b, :string
    field :dismissed_at, :integer
  end

  def changeset(pair, attrs) do
    pair
    |> cast(attrs, [:id, :project_id, :post_id_a, :post_id_b, :dismissed_at])
    |> validate_required([:id, :project_id, :post_id_a, :post_id_b, :dismissed_at])
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:post_id_a, name: :dismissed_pairs_idx)
  end
end
