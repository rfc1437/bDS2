defmodule BDS.Maintenance do
  @moduledoc false

  import Ecto.Query

  alias BDS.Frontmatter
  alias BDS.DocumentFields
  alias BDS.Metadata
  alias BDS.Media.Media
  alias BDS.Media.Translation, as: MediaTranslation
  alias BDS.Embeddings
  alias BDS.Posts.Post
  alias BDS.Posts.Translation, as: PostTranslation
  alias BDS.Persistence
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Sidecar
  alias BDS.Templates.Template

  def repair_metadata_diff(project_id, direction, items, opts \\ [])

  def repair_metadata_diff(project_id, direction, items, opts)
      when is_binary(project_id) and is_list(items) do
    on_progress = progress_callback(opts)
    total = length(items)
    :ok = report_started(on_progress, total, "Repairing metadata differences")

    normalized_direction = normalize_repair_direction(direction)

    result =
      case repair_embedding_batch(project_id, normalized_direction, items, on_progress, total) do
        {:ok, batch_result} ->
          batch_result

        :unsupported ->
          items
          |> Enum.with_index(1)
          |> Enum.reduce(%{repaired: 0, failed: 0}, fn {item, index}, acc ->
            next_acc =
              case repair_metadata_diff_item(project_id, normalized_direction, item) do
                :ok -> %{acc | repaired: acc.repaired + 1}
                {:ok, _value} -> %{acc | repaired: acc.repaired + 1}
                _error -> %{acc | failed: acc.failed + 1}
              end

            :ok = report_progress(on_progress, index, total, "Repairing metadata differences")
            next_acc
          end)
      end

    {:ok, result}
  end

  def import_metadata_diff_orphans(project_id, orphans, opts \\ [])

  def import_metadata_diff_orphans(project_id, orphans, opts)
      when is_binary(project_id) and is_list(orphans) do
    on_progress = progress_callback(opts)
    total = length(orphans)
    :ok = report_started(on_progress, total, "Importing orphan files")

    result =
      orphans
      |> Enum.with_index(1)
      |> Enum.reduce(%{imported: 0, failed: 0}, fn {orphan, index}, acc ->
        next_acc =
          case import_metadata_diff_orphan(project_id, orphan) do
            {:ok, _value} -> %{acc | imported: acc.imported + 1}
            _error -> %{acc | failed: acc.failed + 1}
          end

        :ok = report_progress(on_progress, index, total, "Importing orphan files")
        next_acc
      end)

    {:ok, result}
  end

  def rebuild_from_filesystem(project_id, entity_type, opts \\ []) do
    case normalize_entity_type(entity_type) do
      :post -> BDS.Posts.rebuild_posts_from_files(project_id, opts)
      :media -> BDS.Media.rebuild_media_from_files(project_id, opts)
      :script -> BDS.Scripts.rebuild_scripts_from_files(project_id, opts)
      :template -> BDS.Templates.rebuild_templates_from_files(project_id, opts)
      :embedding -> Embeddings.rebuild_project(project_id)
      :unsupported -> {:error, :unsupported_entity_type}
    end
  end

  def metadata_diff(project_id, opts \\ [])

  def metadata_diff(project_id, opts) when is_binary(project_id) and is_list(opts) do
    project = Projects.get_project!(project_id)
    on_progress = progress_callback(opts)

    phases = [
      {"Comparing project metadata", fn -> project_metadata_diff_reports(project_id) end},
      {"Comparing post metadata", fn -> post_diff_reports(project_id, project) end},
      {"Comparing post translations", fn -> post_translation_diff_reports(project_id, project) end},
      {"Comparing media metadata", fn -> media_diff_reports(project_id, project) end},
      {"Comparing media translations", fn -> media_translation_diff_reports(project_id, project) end},
      {"Comparing script metadata", fn -> script_diff_reports(project_id, project) end},
      {"Comparing template metadata", fn -> template_diff_reports(project_id, project) end},
      {"Comparing embeddings", fn -> Embeddings.diff_reports(project_id) end}
    ]

    total_phases = length(phases) + 1

    diff_reports =
      phases
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{label, fun}, index} ->
        :ok = report_metadata_diff_phase(on_progress, index, total_phases, label)
        fun.()
      end)

    :ok = report_metadata_diff_phase(on_progress, total_phases, total_phases, "Scanning orphan files")
    orphan_reports = orphan_reports(project_id, project)
    :ok = report_metadata_diff_complete(on_progress)

    {:ok, %{diff_reports: diff_reports, orphan_reports: orphan_reports}}
  end

  defp project_metadata_diff_reports(project_id) do
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
              diff_field("status", post.status, DocumentFields.get(fields, "status")),
              diff_field("template_slug", post.template_slug, DocumentFields.get(fields, "templateSlug")),
              diff_field("created_at", post.created_at, DocumentFields.get(fields, "createdAt")),
              diff_field("updated_at", post.updated_at, DocumentFields.get(fields, "updatedAt")),
              diff_field("published_at", post.published_at, DocumentFields.get(fields, "publishedAt")),
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
              diff_field("created_at", script.created_at, DocumentFields.get(fields, "createdAt")),
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
              diff_field("created_at", template.created_at, DocumentFields.get(fields, "createdAt")),
              diff_field("updated_at", template.updated_at, DocumentFields.get(fields, "updatedAt"))
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

  defp build_diff_report(entity_type, entity_id, differences) do
    build_diff_report(entity_type, entity_id, differences, [])
  end

  defp build_diff_report(entity_type, entity_id, differences, opts) do
    normalized = Enum.reject(differences, &is_nil/1)

    if normalized == [] do
      nil
    else
      %{
        entity_type: entity_type,
        entity_id: entity_id,
        differences: normalized,
        label: Keyword.get(opts, :label),
        meta_label: Keyword.get(opts, :meta_label)
      }
    end
  end

  defp metadata_diff_entity_label(title, slug, fallback_id) do
    blank_to_nil(title) || blank_to_nil(slug) || fallback_id
  end

  defp metadata_diff_timestamp_label(nil), do: nil
  defp metadata_diff_timestamp_label(timestamp), do: Persistence.timestamp_to_iso8601(timestamp)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp diff_field(name, db_value, file_value) do
    if equal_diff_values?(db_value, file_value) do
      nil
    else
      %{name: name, db_value: stringify_value(db_value), file_value: stringify_value(file_value)}
    end
  end

  defp equal_diff_values?(left, right) when is_list(left) and is_list(right) do
    normalize_list_diff_values(left) == normalize_list_diff_values(right)
  end

  defp equal_diff_values?(left, right) when is_map(left) and is_map(right) do
    normalize_map_diff_values(left) == normalize_map_diff_values(right)
  end

  defp equal_diff_values?(left, right), do: stringify_value(left) == stringify_value(right)

  defp normalize_list_diff_values(values) do
    values
    |> Enum.map(&stringify_value/1)
    |> Enum.sort()
  end

  defp stringify_value(nil), do: ""
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_boolean(value), do: to_string(value)
  defp stringify_value(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_value(value) when is_binary(value), do: value

  defp stringify_value(value) when is_map(value),
    do: value |> normalize_map_diff_values() |> Jason.encode!()

  defp stringify_value(value) when is_list(value),
    do: Enum.map_join(value, ",", &stringify_value/1)

  defp stringify_value(value), do: to_string(value)

  defp normalize_map_diff_values(values) when is_map(values) do
    values
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_nested_diff_value(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp normalize_nested_diff_value(value) when is_map(value), do: normalize_map_diff_values(value)
  defp normalize_nested_diff_value(value) when is_list(value), do: Enum.map(value, &normalize_nested_diff_value/1)
  defp normalize_nested_diff_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_nested_diff_value(value), do: value

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

  defp repair_metadata_diff_item(project_id, direction, item) do
    entity_type = Map.get(item, :entity_type) || Map.get(item, "entity_type")
    entity_id = Map.get(item, :entity_id) || Map.get(item, "entity_id")

    case {normalize_repair_direction(direction), entity_type} do
      {:file_to_db, entity_type} when entity_type in ["project", "categories", "category_meta", "publishing"] ->
        Metadata.sync_project_metadata_from_filesystem(project_id)

      {:db_to_file, entity_type} when entity_type in ["project", "categories", "category_meta", "publishing"] ->
        Metadata.flush_project_metadata_to_filesystem(project_id)

      {:file_to_db, "post"} -> BDS.Posts.sync_post_from_file(entity_id)
      {:db_to_file, "post"} -> BDS.Posts.rewrite_published_post(entity_id)
      {:file_to_db, "post_translation"} -> BDS.Posts.sync_post_translation_from_file(entity_id)
      {:db_to_file, "post_translation"} -> BDS.Posts.rewrite_published_post_translation(entity_id)
      {:file_to_db, "media"} -> BDS.Media.sync_media_from_sidecar(entity_id)
      {:db_to_file, "media"} -> BDS.Media.sync_media_sidecar(entity_id)
      {:file_to_db, "media_translation"} -> BDS.Media.sync_media_translation_from_sidecar(entity_id)
      {:db_to_file, "media_translation"} -> BDS.Media.sync_media_translation_sidecar(entity_id)
      {:file_to_db, "script"} -> BDS.Scripts.sync_script_from_file(entity_id)
      {:db_to_file, "script"} -> BDS.Scripts.sync_published_script_file(entity_id)
      {:file_to_db, "template"} -> BDS.Templates.sync_template_from_file(entity_id)
      {:db_to_file, "template"} -> BDS.Templates.sync_published_template_file(entity_id)
      {:file_to_db, "embedding"} -> BDS.Embeddings.sync_post(entity_id)
      {:db_to_file, "embedding"} -> BDS.Embeddings.refresh_snapshot(project_id)
      _other -> {:error, :unsupported}
    end
  end

  defp repair_embedding_batch(project_id, direction, items, on_progress, total)
       when direction in [:file_to_db, :db_to_file] do
    if items != [] and Enum.all?(items, &(metadata_diff_item_entity_type(&1) == "embedding")) do
      result =
        case direction do
          :file_to_db ->
            post_ids = Enum.map(items, &metadata_diff_item_entity_id/1)

            case Embeddings.repair_posts(project_id, post_ids) do
              {:ok, repaired_post_ids} ->
                repaired_post_ids = MapSet.new(repaired_post_ids)

                build_batch_repair_result(items, total, on_progress, fn item ->
                  MapSet.member?(repaired_post_ids, metadata_diff_item_entity_id(item))
                end)

              _other ->
                build_batch_repair_result(items, total, on_progress, fn _item -> false end)
            end

          :db_to_file ->
            repaired? = Embeddings.refresh_snapshot(project_id) == :ok
            build_batch_repair_result(items, total, on_progress, fn _item -> repaired? end)
        end

      {:ok, result}
    else
      :unsupported
    end
  end

  defp repair_embedding_batch(_project_id, _direction, _items, _on_progress, _total), do: :unsupported

  defp build_batch_repair_result(items, total, on_progress, repaired?) do
    items
    |> Enum.with_index(1)
    |> Enum.reduce(%{repaired: 0, failed: 0}, fn {item, index}, acc ->
      next_acc =
        if repaired?.(item) do
          %{acc | repaired: acc.repaired + 1}
        else
          %{acc | failed: acc.failed + 1}
        end

      :ok = report_progress(on_progress, index, total, "Repairing metadata differences")
      next_acc
    end)
  end

  defp metadata_diff_item_entity_type(item) do
    Map.get(item, :entity_type) || Map.get(item, "entity_type")
  end

  defp metadata_diff_item_entity_id(item) do
    Map.get(item, :entity_id) || Map.get(item, "entity_id")
  end

  defp import_metadata_diff_orphan(project_id, orphan) do
    file_path = Map.get(orphan, :file_path) || Map.get(orphan, "file_path")

    cond do
      is_nil(file_path) ->
        {:error, :not_found}

      translation_post_file?(file_path) ->
        BDS.Posts.import_orphan_post_translation_file(project_id, file_path)

      String.ends_with?(file_path, ".md") ->
        BDS.Posts.import_orphan_post_file(project_id, file_path)

      translation_media_sidecar?(file_path) ->
        BDS.Media.import_orphan_media_translation_sidecar(project_id, file_path)

      canonical_media_sidecar?(file_path) and String.ends_with?(file_path, ".meta") ->
        BDS.Media.import_orphan_media_sidecar(project_id, file_path)

      String.ends_with?(file_path, ".lua") ->
        BDS.Scripts.import_orphan_script_file(project_id, file_path)

      String.ends_with?(file_path, ".liquid") ->
        BDS.Templates.import_orphan_template_file(project_id, file_path)

      true ->
        {:error, :unsupported}
    end
  end

  defp normalize_repair_direction(:file_to_db), do: :file_to_db
  defp normalize_repair_direction(:db_to_file), do: :db_to_file
  defp normalize_repair_direction("file_to_db"), do: :file_to_db
  defp normalize_repair_direction("db_to_file"), do: :db_to_file
  defp normalize_repair_direction(_direction), do: :unsupported

  defp progress_callback(opts) do
    case Keyword.get(opts, :on_progress) do
      callback when is_function(callback, 2) -> callback
      _other -> nil
    end
  end

  defp report_metadata_diff_phase(nil, _current, _total, _label), do: :ok

  defp report_metadata_diff_phase(callback, current, total, label) do
    value = if total <= 1, do: 0.0, else: (current - 1) / total
    callback.(value, "#{label} (#{current}/#{total})")
    :ok
  end

  defp report_metadata_diff_complete(nil), do: :ok

  defp report_metadata_diff_complete(callback) do
    callback.(1.0, "Metadata diff complete")
    :ok
  end

  defp report_started(nil, _total, _label), do: :ok

  defp report_started(callback, 0, label) do
    callback.(1.0, label)
    :ok
  end

  defp report_started(callback, total, label) do
    callback.(0.05, "#{label} (0/#{total})")
    :ok
  end

  defp report_progress(nil, _current, _total, _label), do: :ok
  defp report_progress(_callback, _current, 0, _label), do: :ok

  defp report_progress(callback, current, total, label) do
    callback.(0.05 + 0.95 * (current / total), "#{label} (#{current}/#{total})")
    :ok
  end
end
