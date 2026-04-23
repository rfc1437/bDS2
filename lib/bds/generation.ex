defmodule BDS.Generation do
  @moduledoc false

  import Ecto.Query

  alias BDS.Generation.GeneratedFileHash
  alias BDS.Projects
  alias BDS.Repo

  def write_generated_file(project_id, relative_path, content)
      when is_binary(project_id) and is_binary(relative_path) and is_binary(content) do
    project = Projects.get_project!(project_id)
    content_hash = sha256(content)
    now = System.system_time(:second)

    case Repo.get_by(GeneratedFileHash, project_id: project_id, relative_path: relative_path) do
      %GeneratedFileHash{content_hash: ^content_hash} ->
        {:ok, %{relative_path: relative_path, content_hash: content_hash, written?: false}}

      _existing ->
        full_path = output_path(project, relative_path)
        :ok = File.mkdir_p(Path.dirname(full_path))
        :ok = File.write(full_path, content)

        attrs = %{
          project_id: project_id,
          relative_path: relative_path,
          content_hash: content_hash,
          updated_at: now
        }

        %GeneratedFileHash{}
        |> GeneratedFileHash.changeset(attrs)
        |> Repo.insert!(
          on_conflict: [set: [content_hash: content_hash, updated_at: now]],
          conflict_target: [:project_id, :relative_path]
        )

        {:ok, %{relative_path: relative_path, content_hash: content_hash, written?: true}}
    end
  end

  def list_generated_files(project_id) when is_binary(project_id) do
    {:ok,
     Repo.all(
       from generated_file in GeneratedFileHash,
         where: generated_file.project_id == ^project_id,
         order_by: [asc: generated_file.relative_path]
     )}
  end

  def delete_generated_file(project_id, relative_path) when is_binary(project_id) and is_binary(relative_path) do
    project = Projects.get_project!(project_id)

    case File.rm(output_path(project, relative_path)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end

    Repo.delete_all(
      from generated_file in GeneratedFileHash,
        where: generated_file.project_id == ^project_id and generated_file.relative_path == ^relative_path
    )

    :ok
  end

  defp output_path(project, relative_path) do
    Path.join([Projects.project_data_dir(project), "html", relative_path])
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
