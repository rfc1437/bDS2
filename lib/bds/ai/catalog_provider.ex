defmodule BDS.AI.CatalogProvider do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "ai_providers" do
    field :name, :string
    field :env_keys, :string, source: :env
    field :package_ref, :string
    field :api_url, :string, source: :api
    field :doc_url, :string, source: :doc
    field :updated_at, :integer
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:id, :name, :env_keys, :package_ref, :api_url, :doc_url, :updated_at],
      empty_values: [nil]
    )
    |> validate_required([:id, :name, :updated_at])
  end
end
