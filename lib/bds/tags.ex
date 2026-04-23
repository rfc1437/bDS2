defmodule BDS.Tags do
  @moduledoc false

  import Ecto.Query

  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Tags.Tag

  def create_tag(attrs) do
    project_id = attr(attrs, :project_id)
    name = attr(attrs, :name) |> to_string() |> String.trim()

    with :ok <- validate_unique_name(project_id, name) do
      now = System.system_time(:second)

      %Tag{}
      |> Tag.changeset(%{
        id: Ecto.UUID.generate(),
        project_id: project_id,
        name: name,
        color: attr(attrs, :color),
        post_template_slug: attr(attrs, :post_template_slug),
        created_at: now,
        updated_at: now
      })
      |> Repo.insert()
      |> case do
        {:ok, tag} ->
          write_tags_json(project_id)
          {:ok, tag}

        error ->
          error
      end
    end
  end

  def list_tags(project_id) do
    Repo.all(from tag in Tag, where: tag.project_id == ^project_id, order_by: [asc: tag.name])
  end

  defp write_tags_json(project_id) do
    project = Projects.get_project!(project_id)
    path = Path.join([Projects.project_data_dir(project), "meta", "tags.json"])
    :ok = File.mkdir_p(Path.dirname(path))

    payload = %{
      "tags" =>
        project_id
        |> list_tags()
        |> Enum.sort_by(&String.downcase(&1.name))
        |> Enum.map(fn tag ->
          %{"name" => tag.name}
          |> maybe_put("color", tag.color)
          |> maybe_put("post_template_slug", tag.post_template_slug)
        end)
    }

    File.write!(path, Jason.encode!(payload))
  end

  defp validate_unique_name(project_id, name) do
    if Repo.exists?(from tag in Tag, where: tag.project_id == ^project_id and fragment("lower(?)", tag.name) == ^String.downcase(name)) do
      {:error,
       %Tag{}
       |> Tag.changeset(%{project_id: project_id, name: name, id: Ecto.UUID.generate(), created_at: 0, updated_at: 0})
       |> Ecto.Changeset.add_error(:name, "has already been taken")}
    else
      :ok
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
