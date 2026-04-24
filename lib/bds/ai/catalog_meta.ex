defmodule BDS.AI.CatalogMeta do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}

  schema "ai_catalog_meta" do
    field :value, :string
  end

  def changeset(meta, attrs) do
    meta
    |> cast(attrs, [:key, :value], empty_values: [nil])
    |> validate_required([:key, :value])
  end
end
