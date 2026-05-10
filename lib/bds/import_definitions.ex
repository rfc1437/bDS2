defmodule BDS.ImportDefinitions do
  @moduledoc """
  CRUD operations for import definitions — saved configurations for importing
  content from WordPress WXR exports.
  """

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
      last_analysis_result: normalize_analysis_result(attr(attrs, :last_analysis_result)),
      created_at: now,
      updated_at: now
    })
    |> Repo.insert()
  end

  def get_definition(definition_id) when is_binary(definition_id) do
    Repo.get(ImportDefinition, definition_id)
  end

  def update_definition(definition_id, attrs) when is_binary(definition_id) and is_map(attrs) do
    case Repo.get(ImportDefinition, definition_id) do
      nil ->
        {:error, :not_found}

      %ImportDefinition{} = definition ->
        updates =
          %{}
          |> maybe_put(:name, attr(attrs, :name))
          |> maybe_put(:wxr_file_path, attr(attrs, :wxr_file_path))
          |> maybe_put(:uploads_folder_path, attr(attrs, :uploads_folder_path))
          |> maybe_put(
            :last_analysis_result,
            normalize_analysis_result(attr(attrs, :last_analysis_result))
          )
          |> Map.put(:updated_at, Persistence.now_ms())

        definition
        |> ImportDefinition.changeset(updates)
        |> Repo.update()
    end
  end

  def delete_definition(definition_id) when is_binary(definition_id) do
    with %ImportDefinition{} = definition <- Repo.get(ImportDefinition, definition_id),
         {:ok, _deleted} <- Repo.delete(definition) do
      {:ok, :deleted}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def decode_analysis_result(%ImportDefinition{last_analysis_result: result}),
    do: decode_analysis_result(result)

  def decode_analysis_result(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, value} -> atomize_keys(value)
      {:error, _reason} -> nil
    end
  end

  def decode_analysis_result(_result), do: nil

  def list_definitions(project_id) do
    Repo.all(
      from definition in ImportDefinition,
        where: definition.project_id == ^project_id,
        order_by: [desc: definition.updated_at, desc: definition.created_at],
        select: %{id: definition.id, title: definition.name, updated_at: definition.updated_at}
    )
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  alias BDS.MapUtils

  defp normalize_analysis_result(nil), do: nil
  defp normalize_analysis_result(value) when is_binary(value), do: value
  defp normalize_analysis_result(value), do: Jason.encode!(value)

  defp atomize_keys(value), do: MapUtils.safe_atomize_keys(value)
end
