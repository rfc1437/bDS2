defmodule BDS.AI.ModelModality do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "ai_model_modalities" do
    field :provider, :string, primary_key: true
    field :model_id, :string, primary_key: true
    field :direction, Ecto.Enum, values: [:input, :output], primary_key: true
    field :modality, Ecto.Enum, values: [:text, :image, :audio, :file, :tool], primary_key: true
  end

  def changeset(modality, attrs) do
    modality
    |> cast(attrs, [:provider, :model_id, :direction, :modality], empty_values: [nil])
    |> validate_required([:provider, :model_id, :direction, :modality])
  end
end
