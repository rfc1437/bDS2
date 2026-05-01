defmodule BDS.Maintenance.DiffReports do
  @moduledoc false

  import Ecto.Query

  import BDS.Maintenance.DiffComputation,
    only: [
      build_diff_report: 3,
      build_diff_report: 4,
      diff_field: 3,
      metadata_diff_entity_label: 3,
      metadata_diff_timestamp_label: 1
    ]

  import BDS.Maintenance.FileScan,
    only: [
      read_frontmatter_document: 2,
      read_sidecar_document: 2,
      media_translation_sidecar_path: 2
    ]

  alias BDS.DocumentFields
  alias BDS.Media.Media
  alias BDS.Media.Translation, as: MediaTranslation
  alias BDS.Metadata
  alias BDS.Posts.Post
  alias BDS.Posts.Translation, as: PostTranslation
  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Templates.Template

  def project_metadata_diff_reports(project_id) do
    {:ok, db_state} = Metadata.get_project_metadata(project_id)
    {:ok, filesystem_state} = Metadata.read_project_metadata_from_filesystem(project_id)

    [
      build_diff_report("project", project_id, [
        diff_field("name", db_state.name, filesystem_state.name),
        diff_field("description", db_state.description, filesystem_state.description),
        diff_field("public_url", db_state.public_url, filesystem_state.public_url),
        diff_field("main_language", db_state.main_language, filesystem_state.main_language),
        diff_field("default_author", db_state.default_author, filesystem_state.default_author),
        diff_field(
          "max_posts_per_page",
          db_state.max_posts_per_page,
          filesystem_state.max_posts_per_page
        ),
        diff_field(
          "blogmark_category",
          db_state.blogmark_category,
          filesystem_state.blogmark_category
        ),
        diff_field("pico_theme", db_state.pico_theme, filesystem_state.pico_theme),
        diff_field(
          "semantic_similarity_enabled",
          db_state.semantic_similarity_enabled,
          filesystem_state.semantic_similarity_enabled
        ),
        diff_field("blog_languages", db_state.blog_languages, filesystem_state.blog_languages)
      ]),
      build_diff_report("categories", project_id, [
        diff_field("categories", db_state.categories, filesystem_state.categories)
      ]),
      build_diff_report("category_meta", project_id, [
        diff_field(
          "category_settings",
          db_state.category_settings,
          filesystem_state.category_settings
        )
      ]),
      build_diff_report("publishing", project_id, [
        diff_field(
          "ssh_host",
          Map.get(db_state.publishing_preferences, "ssh_host"),
          Map.get(filesystem_state.publishing_preferences, "ssh_host")
        ),
        diff_field(
          "ssh_user",
          Map.get(db_state.publishing_preferences, "ssh_user"),
          Map.get(filesystem_state.publishing_preferences, "ssh_user")
        ),
        diff_field(
          "ssh_remote_path",
          Map.get(db_state.publishing_preferences, "ssh_remote_path"),
          Map.get(filesystem_state.publishing_preferences, "ssh_remote_path")
        ),
        diff_field(
          "ssh_mode",
          Map.get(db_state.publishing_preferences, "ssh_mode"),
          Map.get(filesystem_state.publishing_preferences, "ssh_mode")
        )
      ])
    ]
    |> Enum.reject(&is_nil/1)
  end

  def post_diff_reports(project_id, project) do
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
              diff_field("status", post.status, DocumentFields.get(fields, "status")),
              diff_field(
                "template_slug",
                post.template_slug,
                DocumentFields.get(fields, "templateSlug")
              ),
              diff_field("created_at", post.created_at, DocumentFields.get(fields, "createdAt")),
              diff_field("updated_at", post.updated_at, DocumentFields.get(fields, "updatedAt")),
              diff_field(
                "published_at",
                post.published_at,
                DocumentFields.get(fields, "publishedAt")
              ),
              diff_field("tags", post.tags, Map.get(fields, "tags", [])),
              diff_field("categories", post.categories, Map.get(fields, "categories", []))
            ]
            |> Enum.reject(&is_nil/1)

          if differences == [] do
            []
          else
            [
              build_diff_report("post", post.id, differences,
                label: metadata_diff_entity_label(post.title, post.slug, post.id),
                meta_label: metadata_diff_timestamp_label(post.created_at)
              )
            ]
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  def media_diff_reports(project_id, project) do
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
              diff_field("created_at", media.created_at, DocumentFields.get(fields, "createdAt")),
              diff_field("updated_at", media.updated_at, DocumentFields.get(fields, "updatedAt")),
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

  def post_translation_diff_reports(project_id, project) do
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
              diff_field(
                "translation_for",
                translation.translation_for,
                DocumentFields.get(fields, "translationFor")
              )
            ]
            |> Enum.reject(&is_nil/1)

          if differences == [] do
            []
          else
            [
              build_diff_report("post_translation", translation.id, differences,
                label: metadata_diff_entity_label(translation.title, nil, translation.id),
                meta_label: translation.language
              )
            ]
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  def media_translation_diff_reports(project_id, project) do
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
                DocumentFields.get(fields, "translationFor")
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

  def script_diff_reports(project_id, project) do
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
              diff_field(
                "created_at",
                script.created_at,
                DocumentFields.get(fields, "createdAt")
              ),
              diff_field("updated_at", script.updated_at, DocumentFields.get(fields, "updatedAt"))
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

  def template_diff_reports(project_id, project) do
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
              diff_field(
                "created_at",
                template.created_at,
                DocumentFields.get(fields, "createdAt")
              ),
              diff_field(
                "updated_at",
                template.updated_at,
                DocumentFields.get(fields, "updatedAt")
              )
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
end
