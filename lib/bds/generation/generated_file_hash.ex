defmodule BDS.Generation.GeneratedFileHash do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  schema "generated_file_hashes" do
    field :project_id, :string
    field :relative_path, :string
    field :content_hash, :string
    field :updated_at, :integer
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:project_id, :relative_path, :content_hash, :updated_at], empty_values: [nil])
    |> validate_required([:project_id, :relative_path, :content_hash, :updated_at])
    |> unique_constraint(:relative_path, name: :generated_file_hashes_project_path_idx)
  end
end