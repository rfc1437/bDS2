defmodule BDS.Maintenance.FileScan do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.Media.Media
  alias BDS.Media.Translation, as: MediaTranslation
  alias BDS.Posts.Post
  alias BDS.Posts.Translation, as: PostTranslation
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Sidecar
  alias BDS.Templates.Template

  def orphan_reports(project_id, project) do
    post_paths =
      MapSet.new(
        Repo.all(from post in Post, where: post.project_id == ^project_id, select: post.file_path)
      )

    media_paths =
      MapSet.new(
        Repo.all(
          from media in Media, where: media.project_id == ^project_id, select: media.sidecar_path
        )
      )

    post_translation_paths =
      MapSet.new(
        Repo.all(
          from translation in PostTranslation,
            where: translation.project_id == ^project_id,
            select: translation.file_path
        )
      )

    media_translation_paths = MapSet.new(media_translation_sidecar_paths(project_id))

    script_paths =
      MapSet.new(
        Repo.all(
          from script in Script, where: script.project_id == ^project_id, select: script.file_path
        )
      )

    template_paths =
      MapSet.new(
        Repo.all(
          from template in Template,
            where: template.project_id == ^project_id,
            select: template.file_path
        )
      )

    post_orphans =
      project
      |> list_project_files("posts/**/*.md")
      |> Enum.map(&Path.relative_to(&1, Projects.project_data_dir(project)))
      |> Enum.reject(&translation_post_file?/1)
      |> Enum.reject(&MapSet.member?(post_paths, &1))

    post_translation_orphans =
      project
      |> list_project_files("posts/**/*.md")
      |> Enum.map(&Path.relative_to(&1, Projects.project_data_dir(project)))
      |> Enum.filter(&translation_post_file?/1)
      |> Enum.reject(&MapSet.member?(post_translation_paths, &1))

    media_orphans =
      project
      |> list_project_files("media/**/*.meta")
      |> Enum.map(&Path.relative_to(&1, Projects.project_data_dir(project)))
      |> Enum.filter(&canonical_media_sidecar?/1)
      |> Enum.reject(&MapSet.member?(media_paths, &1))

    media_translation_orphans =
      project
      |> list_project_files("media/**/*.meta")
      |> Enum.map(&Path.relative_to(&1, Projects.project_data_dir(project)))
      |> Enum.filter(&translation_media_sidecar?/1)
      |> Enum.reject(&MapSet.member?(media_translation_paths, &1))

    script_orphans =
      project
      |> list_project_files("scripts/**/*.lua")
      |> Enum.map(&Path.relative_to(&1, Projects.project_data_dir(project)))
      |> Enum.reject(&MapSet.member?(script_paths, &1))

    template_orphans =
      project
      |> list_project_files("templates/*.liquid")
      |> Enum.map(&Path.relative_to(&1, Projects.project_data_dir(project)))
      |> Enum.reject(&MapSet.member?(template_paths, &1))

    (post_orphans ++
       post_translation_orphans ++
       media_orphans ++ media_translation_orphans ++ script_orphans ++ template_orphans)
    |> Enum.sort()
    |> Enum.map(&%{file_path: &1})
  end

  def read_frontmatter_document(project, relative_path) do
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    case File.read(full_path) do
      {:ok, contents} -> Frontmatter.parse_document(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  def read_sidecar_document(project, relative_path) do
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    case File.read(full_path) do
      {:ok, contents} -> Sidecar.parse_document(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  def list_project_files(project, glob) do
    project
    |> Projects.project_data_dir()
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.sort()
  end

  def canonical_media_sidecar?(relative_path) do
    not Regex.match?(~r/\.[a-z]{2}\.meta$/i, relative_path)
  end

  def translation_post_file?(relative_path) do
    Regex.match?(~r/\.[a-z]{2}\.md$/i, relative_path)
  end

  def translation_media_sidecar?(relative_path) do
    Regex.match?(~r/\.[a-z]{2}\.meta$/i, relative_path)
  end

  def media_translation_sidecar_paths(project_id) do
    Repo.all(from translation in MediaTranslation, where: translation.project_id == ^project_id)
    |> Enum.map(&media_translation_sidecar_path(project_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  def media_translation_sidecar_path(project_id, translation) do
    case Repo.one(
           from media in Media,
             where: media.project_id == ^project_id and media.id == ^translation.translation_for,
             select: media.file_path
         ) do
      nil -> nil
      file_path -> "#{file_path}.#{translation.language}.meta"
    end
  end
end
