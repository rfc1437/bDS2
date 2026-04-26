defmodule BDS.ImportDefinitions do
  @moduledoc false

  import Ecto.Query

  alias BDS.ImportDefinitions.ImportDefinition
  alias BDS.Persistence
  alias BDS.Repo

  def create_definition(attrs) do
    now = Persistence.now_ms()

    %ImportDefinition{}
    |> ImportDefinition.changeset(%{
      id: Ecto.UUID.generate(),
      project_id: attr(attrs, :project_id),
      name: attr(attrs, :name) || "",
      wxr_file_path: attr(attrs, :wxr_file_path),
      uploads_folder_path: attr(attrs, :uploads_folder_path),
      last_analysis_result: attr(attrs, :last_analysis_result),
      created_at: now,
      updated_at: now
    })
    |> Repo.insert()
  end

  def list_definitions(project_id) do
    Repo.all(
      from definition in ImportDefinition,
        where: definition.project_id == ^project_id,
        order_by: [desc: definition.updated_at, desc: definition.created_at],
        select: %{id: definition.id, title: definition.name, updated_at: definition.updated_at}
    )
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
