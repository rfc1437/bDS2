defmodule BDS.ImportDefinitions.ImportDefinition do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "import_definitions" do
    field :project_id, :string
    field :name, :string
    field :wxr_file_path, :string
    field :uploads_folder_path, :string
    field :last_analysis_result, :string
    field :created_at, :integer
    field :updated_at, :integer
  end

  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [
      :id,
      :project_id,
      :name,
      :wxr_file_path,
      :uploads_folder_path,
      :last_analysis_result,
      :created_at,
      :updated_at
    ])
    |> validate_required([:id, :project_id, :name, :created_at, :updated_at])
  end
end
