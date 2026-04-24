defmodule BDS.Maintenance do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.Media.Media
  alias BDS.Media.Translation, as: MediaTranslation
  alias BDS.Embeddings
  alias BDS.Posts.Post
  alias BDS.Posts.Translation, as: PostTranslation
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Sidecar
  alias BDS.Templates.Template

  def rebuild_from_filesystem(project_id, entity_type) do
    case normalize_entity_type(entity_type) do
      :post -> BDS.Posts.rebuild_posts_from_files(project_id)
      :media -> BDS.Media.rebuild_media_from_files(project_id)
      :script -> BDS.Scripts.rebuild_scripts_from_files(project_id)
      :template -> BDS.Templates.rebuild_templates_from_files(project_id)
      :embedding -> Embeddings.rebuild_project(project_id)
      :unsupported -> {:error, :unsupported_entity_type}
    end
  end

  def metadata_diff(project_id) when is_binary(project_id) do
    project = Projects.get_project!(project_id)

    diff_reports =
      post_diff_reports(project_id, project) ++
        post_translation_diff_reports(project_id, project) ++
        media_diff_reports(project_id, project) ++
        media_translation_diff_reports(project_id, project) ++
        script_diff_reports(project_id, project) ++
        template_diff_reports(project_id, project) ++
        Embeddings.diff_reports(project_id)

    orphan_reports = orphan_reports(project_id, project)

    {:ok, %{diff_reports: diff_reports, orphan_reports: orphan_reports}}
  end

  defp normalize_entity_type(:post), do: :post
  defp normalize_entity_type(:media), do: :media
  defp normalize_entity_type(:script), do: :script
  defp normalize_entity_type(:template), do: :template
  defp normalize_entity_type(:embedding), do: :embedding
  defp normalize_entity_type("post"), do: :post
  defp normalize_entity_type("media"), do: :media
  defp normalize_entity_type("script"), do: :script
  defp normalize_entity_type("template"), do: :template
  defp normalize_entity_type("embedding"), do: :embedding
  defp normalize_entity_type("embeddings"), do: :embedding
  defp normalize_entity_type(_entity_type), do: :unsupported

  defp post_diff_reports(project_id, project) do
    Repo.all(
      from post in Post,
        where:
          post.project_id == ^project_id and not is_nil(post.file_path) and post.file_path != ""
    )
    |> Enum.flat_map(fn post ->
      case read_frontmatter_document(project, post.file_path) do
        {:ok, %{fields: fields}} ->
          differences =
            [
              diff_field("title", post.title, Map.get(fields, "title")),
              diff_field("excerpt", post.excerpt, Map.get(fields, "excerpt")),
              diff_field("author", post.author, Map.get(fields, "author")),
              diff_field("language", post.language, Map.get(fields, "language")),
              diff_field("status", post.status, Map.get(fields, "status")),
              diff_field("template_slug", post.template_slug, Map.get(fields, "template_slug")),
              diff_field("created_at", post.created_at, Map.get(fields, "created_at")),
              diff_field("updated_at", post.updated_at, Map.get(fields, "updated_at")),
              diff_field("published_at", post.published_at, Map.get(fields, "published_at")),
              diff_field("tags", post.tags, Map.get(fields, "tags", [])),
              diff_field("categories", post.categories, Map.get(fields, "categories", []))
            ]
            |> Enum.reject(&is_nil/1)

          if differences == [] do
            []
          else
            [%{entity_type: "post", entity_id: post.id, differences: differences}]
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  defp media_diff_reports(project_id, project) do
    Repo.all(
      from media in Media,
        where:
          media.project_id == ^project_id and not is_nil(media.sidecar_path) and
            media.sidecar_path != ""
    )
    |> Enum.flat_map(fn media ->
      case read_sidecar_document(project, media.sidecar_path) do
        {:ok, fields} ->
          differences =
            [
              diff_field("title", media.title, Map.get(fields, "title")),
              diff_field("alt", media.alt, Map.get(fields, "alt")),
              diff_field("caption", media.caption, Map.get(fields, "caption")),
              diff_field("author", media.author, Map.get(fields, "author")),
              diff_field("language", media.language, Map.get(fields, "language")),
              diff_field("created_at", media.created_at, Map.get(fields, "created_at")),
              diff_field("updated_at", media.updated_at, Map.get(fields, "updated_at")),
              diff_field("tags", media.tags, Map.get(fields, "tags", []))
            ]
            |> Enum.reject(&is_nil/1)

          if differences == [] do
            []
          else
            [%{entity_type: "media", entity_id: media.id, differences: differences}]
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  defp post_translation_diff_reports(project_id, project) do
    Repo.all(
      from translation in PostTranslation,
        where:
          translation.project_id == ^project_id and not is_nil(translation.file_path) and
            translation.file_path != ""
    )
    |> Enum.flat_map(fn translation ->
      case read_frontmatter_document(project, translation.file_path) do
        {:ok, %{fields: fields}} ->
          differences =
            [
              diff_field("title", translation.title, Map.get(fields, "title")),
              diff_field("excerpt", translation.excerpt, Map.get(fields, "excerpt")),
              diff_field("language", translation.language, Map.get(fields, "language")),
              diff_field("status", translation.status, Map.get(fields, "status")),
              diff_field(
                "translation_for",
                translation.translation_for,
                Map.get(fields, "translation_for")
              ),
              diff_field("created_at", translation.created_at, Map.get(fields, "created_at")),
              diff_field("updated_at", translation.updated_at, Map.get(fields, "updated_at")),
              diff_field(
                "published_at",
                translation.published_at,
                Map.get(fields, "published_at")
              )
            ]
            |> Enum.reject(&is_nil/1)

          if differences == [] do
            []
          else
            [
              %{
                entity_type: "post_translation",
                entity_id: translation.id,
                differences: differences
              }
            ]
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  defp media_translation_diff_reports(project_id, project) do
    Repo.all(from translation in MediaTranslation, where: translation.project_id == ^project_id)
    |> Enum.flat_map(fn translation ->
      sidecar_path = media_translation_sidecar_path(project_id, translation)

      case sidecar_path && read_sidecar_document(project, sidecar_path) do
        {:ok, fields} ->
          differences =
            [
              diff_field("title", translation.title, Map.get(fields, "title")),
              diff_field("alt", translation.alt, Map.get(fields, "alt")),
              diff_field("caption", translation.caption, Map.get(fields, "caption")),
              diff_field("language", translation.language, Map.get(fields, "language")),
              diff_field(
                "translation_for",
                translation.translation_for,
                Map.get(fields, "translation_for")
              )
            ]
            |> Enum.reject(&is_nil/1)

          if differences == [] do
            []
          else
            [
              %{
                entity_type: "media_translation",
                entity_id: translation.id,
                differences: differences
              }
            ]
          end

        _ ->
          []
      end
    end)
  end

  defp script_diff_reports(project_id, project) do
    Repo.all(
      from script in Script,
        where:
          script.project_id == ^project_id and not is_nil(script.file_path) and
            script.file_path != ""
    )
    |> Enum.flat_map(fn script ->
      case read_frontmatter_document(project, script.file_path) do
        {:ok, %{fields: fields}} ->
          differences =
            [
              diff_field("title", script.title, Map.get(fields, "title")),
              diff_field("entrypoint", script.entrypoint, Map.get(fields, "entrypoint")),
              diff_field("enabled", script.enabled, Map.get(fields, "enabled")),
              diff_field("created_at", script.created_at, Map.get(fields, "created_at")),
              diff_field("updated_at", script.updated_at, Map.get(fields, "updated_at"))
            ]
            |> Enum.reject(&is_nil/1)

          if differences == [] do
            []
          else
            [%{entity_type: "script", entity_id: script.id, differences: differences}]
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  defp template_diff_reports(project_id, project) do
    Repo.all(
      from template in Template,
        where:
          template.project_id == ^project_id and not is_nil(template.file_path) and
            template.file_path != ""
    )
    |> Enum.flat_map(fn template ->
      case read_frontmatter_document(project, template.file_path) do
        {:ok, %{fields: fields}} ->
          differences =
            [
              diff_field("title", template.title, Map.get(fields, "title")),
              diff_field("enabled", template.enabled, Map.get(fields, "enabled")),
              diff_field("created_at", template.created_at, Map.get(fields, "created_at")),
              diff_field("updated_at", template.updated_at, Map.get(fields, "updated_at"))
            ]
            |> Enum.reject(&is_nil/1)

          if differences == [] do
            []
          else
            [%{entity_type: "template", entity_id: template.id, differences: differences}]
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  defp orphan_reports(project_id, project) do
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

  defp diff_field(name, db_value, file_value) do
    db_value = stringify_value(db_value)
    file_value = stringify_value(file_value)

    if db_value == file_value do
      nil
    else
      %{name: name, db_value: db_value, file_value: file_value}
    end
  end

  defp stringify_value(nil), do: ""
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_boolean(value), do: to_string(value)
  defp stringify_value(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_value(value) when is_binary(value), do: value

  defp stringify_value(value) when is_list(value),
    do: Enum.map_join(value, ",", &stringify_value/1)

  defp stringify_value(value), do: to_string(value)

  defp read_frontmatter_document(project, relative_path) do
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    case File.read(full_path) do
      {:ok, contents} -> Frontmatter.parse_document(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_sidecar_document(project, relative_path) do
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    case File.read(full_path) do
      {:ok, contents} -> Sidecar.parse_document(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_project_files(project, glob) do
    project
    |> Projects.project_data_dir()
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp canonical_media_sidecar?(relative_path) do
    not Regex.match?(~r/\.[a-z]{2}\.meta$/i, relative_path)
  end

  defp translation_post_file?(relative_path) do
    Regex.match?(~r/\.[a-z]{2}\.md$/i, relative_path)
  end

  defp translation_media_sidecar?(relative_path) do
    Regex.match?(~r/\.[a-z]{2}\.meta$/i, relative_path)
  end

  defp media_translation_sidecar_paths(project_id) do
    Repo.all(from translation in MediaTranslation, where: translation.project_id == ^project_id)
    |> Enum.map(&media_translation_sidecar_path(project_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp media_translation_sidecar_path(project_id, translation) do
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
