defmodule BDS.Posts.TranslationValidation do
  @moduledoc false

  import Ecto.Query

  alias BDS.DocumentFields
  alias BDS.Frontmatter
  alias BDS.Metadata
  alias BDS.Posts.Post
  alias BDS.Posts.RebuildFromFiles
  alias BDS.Posts.Translation
  alias BDS.Posts.Translations
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Search

  @type report :: %{
          required(:checked_database_row_count) => non_neg_integer(),
          required(:checked_filesystem_file_count) => non_neg_integer(),
          required(:invalid_database_rows) => [map()],
          required(:invalid_filesystem_files) => [map()],
          required(:missing) => [map()],
          required(:orphan_files) => [String.t()],
          required(:do_not_translate_posts) => [String.t()]
        }

  @doc """
  Validate translation rows + on-disk translation files for a project.

  The result map preserves both the modern invalid-item shape
  (`invalid_database_rows`, `invalid_filesystem_files`, etc.) and the legacy
  summary fields (`missing`, `orphan_files`, `do_not_translate_posts`).
  """
  @spec validate(String.t(), keyword()) :: {:ok, report()}
  def validate(project_id, opts \\ []) do
    project = Projects.get_project!(project_id)
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    on_progress = RebuildFromFiles.progress_callback(opts)

    source_posts =
      Repo.all(
        from post in Post,
          where: post.project_id == ^project_id,
          order_by: [asc: post.created_at, asc: post.slug]
      )

    source_post_map = Map.new(source_posts, &{&1.id, &1})

    translation_rows =
      Repo.all(
        from translation in Translation,
          where: translation.project_id == ^project_id,
          order_by: [
            asc: translation.translation_for,
            asc: translation.language,
            asc: translation.id
          ]
      )

    project_data_dir = Projects.project_data_dir(project)

    markdown_files =
      project_data_dir
      |> Path.join("posts")
      |> list_markdown_files_recursive()

    total_items = length(translation_rows) + length(markdown_files)
    :ok = RebuildFromFiles.report_rebuild_started(on_progress, total_items, "translations")

    invalid_database_rows =
      translation_rows
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {translation, index} ->
        :ok =
          RebuildFromFiles.report_rebuild_progress(
            on_progress,
            index,
            total_items,
            "translations"
          )

        case invalid_database_translation_issue(translation, source_post_map, metadata) do
          nil -> []
          issue -> [issue]
        end
      end)
      |> Enum.sort_by(&issue_sort_key/1)

    {checked_filesystem_file_count, invalid_filesystem_files} =
      markdown_files
      |> Enum.with_index(length(translation_rows) + 1)
      |> Enum.reduce({0, []}, fn {file_path, index}, {count, issues} ->
        :ok =
          RebuildFromFiles.report_rebuild_progress(
            on_progress,
            index,
            total_items,
            "translations"
          )

        case invalid_filesystem_translation_issue(file_path, source_post_map, metadata) do
          {:ok, nil} -> {count + 1, issues}
          {:ok, issue} -> {count + 1, [issue | issues]}
          :skip -> {count, issues}
        end
      end)

    missing = legacy_missing_entries(source_posts, translation_rows, metadata)
    orphan_files = legacy_orphan_files(invalid_filesystem_files, project_data_dir)
    do_not_translate_posts = legacy_do_not_translate_posts(source_posts)

    {:ok,
     %{
       checked_database_row_count: length(translation_rows),
       checked_filesystem_file_count: checked_filesystem_file_count,
       invalid_database_rows: invalid_database_rows,
       invalid_filesystem_files:
         invalid_filesystem_files |> Enum.reverse() |> Enum.sort_by(&issue_sort_key/1),
       missing: missing,
       orphan_files: orphan_files,
       do_not_translate_posts: do_not_translate_posts
     }}
  end

  @doc "Apply fixes for the issues described in a validation `report`."
  @spec fix_invalid(map()) ::
          {:ok,
           %{
             deleted_database_rows: non_neg_integer(),
             deleted_files: non_neg_integer(),
             flushed_translations: non_neg_integer()
           }}
  def fix_invalid(report) when is_map(report) do
    normalized_report = normalize_report(report)

    {deleted_database_rows, flushed_translations, synced_post_ids} =
      Enum.reduce(normalized_report.invalid_database_rows, {0, 0, MapSet.new()}, fn issue,
                                                                                    {deleted,
                                                                                     flushed,
                                                                                     synced_ids} ->
        case fix_invalid_database_row(issue) do
          {:deleted, post_id} ->
            {deleted + 1, flushed, maybe_put_synced_post(synced_ids, post_id)}

          {:flushed, post_id} ->
            {deleted, flushed + 1, maybe_put_synced_post(synced_ids, post_id)}

          :noop ->
            {deleted, flushed, synced_ids}
        end
      end)

    deleted_files =
      Enum.reduce(normalized_report.invalid_filesystem_files, 0, fn issue, count ->
        if delete_validation_file(issue.file_path), do: count + 1, else: count
      end)

    Enum.each(synced_post_ids, &Search.sync_post/1)

    {:ok,
     %{
       deleted_database_rows: deleted_database_rows,
       deleted_files: deleted_files,
       flushed_translations: flushed_translations
     }}
  end

  @doc "True if the parsed rebuild file represents a translation (`translationFor` set, no `slug`)."
  @spec translation_rebuild_file?(map()) :: boolean()
  def translation_rebuild_file?(%{fields: fields}) do
    DocumentFields.has_key?(fields, "translationFor") and
      not DocumentFields.has_key?(fields, "slug")
  end

  @doc "Recursively list `.md`/`.markdown`/`.mdx` files under `dir`."
  @spec list_markdown_files_recursive(String.t()) :: [String.t()]
  def list_markdown_files_recursive(dir) do
    ["*.md", "*.markdown", "*.mdx"]
    |> Enum.flat_map(&list_matching_files(dir, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "List files in `dir` matching `pattern` (recursive glob)."
  @spec list_matching_files(String.t(), String.t()) :: [String.t()]
  def list_matching_files(dir, pattern) do
    if File.dir?(dir) do
      Path.join([dir, "**", pattern])
      |> Path.wildcard()
      |> Enum.sort()
    else
      []
    end
  end

  @doc false
  def normalize_language(value), do: do_normalize_language(value)

  # ----- internals -----

  defp invalid_database_translation_issue(%Translation{} = translation, source_post_map, metadata) do
    source_post = Map.get(source_post_map, translation.translation_for)
    normalized_language = do_normalize_language(translation.language)

    cond do
      is_nil(source_post) ->
        issue(%{
          issue: "missing-source-post",
          translation_id: translation.id,
          translation_for: translation.translation_for,
          translation_language: normalized_language,
          title: translation.title,
          file_path: blank_to_nil(translation.file_path)
        })

      canonical_language?(source_post, normalized_language, metadata) ->
        issue(%{
          issue: "same-language-as-canonical",
          translation_id: translation.id,
          translation_for: translation.translation_for,
          canonical_language: canonical_language(source_post, metadata),
          translation_language: normalized_language,
          title: translation.title,
          file_path: blank_to_nil(translation.file_path)
        })

      source_post.do_not_translate ->
        issue(%{
          issue: "do-not-translate-has-translations",
          translation_id: translation.id,
          translation_for: translation.translation_for,
          translation_language: normalized_language,
          title: translation.title,
          file_path: blank_to_nil(translation.file_path)
        })

      translation.status == :published and present?(translation.content) ->
        issue(%{
          issue: "content-in-database",
          translation_id: translation.id,
          translation_for: translation.translation_for,
          translation_language: normalized_language,
          title: translation.title,
          file_path: blank_to_nil(translation.file_path)
        })

      true ->
        nil
    end
  end

  defp invalid_filesystem_translation_issue(file_path, source_post_map, metadata) do
    with {:ok, contents} <- File.read(file_path),
         {:ok, %{fields: fields}} <- Frontmatter.parse_document(contents),
         true <- translation_rebuild_file?(%{fields: fields}) do
      translation_for = DocumentFields.get(fields, "translationFor")
      source_post = Map.get(source_post_map, translation_for)
      normalized_language = do_normalize_language(DocumentFields.get(fields, "language"))
      title = DocumentFields.get(fields, "title")

      result =
        cond do
          is_nil(source_post) ->
            issue(%{
              issue: "missing-source-post",
              translation_for: translation_for,
              translation_language: normalized_language,
              title: title,
              file_path: file_path
            })

          canonical_language?(source_post, normalized_language, metadata) ->
            issue(%{
              issue: "same-language-as-canonical",
              translation_for: translation_for,
              canonical_language: canonical_language(source_post, metadata),
              translation_language: normalized_language,
              title: title,
              file_path: file_path
            })

          source_post.do_not_translate ->
            issue(%{
              issue: "do-not-translate-has-translations",
              translation_for: translation_for,
              translation_language: normalized_language,
              title: title,
              file_path: file_path
            })

          true ->
            nil
        end

      {:ok, result}
    else
      false -> :skip
      _other -> :skip
    end
  end

  defp normalize_report(report) do
    %{
      checked_database_row_count: map_value(report, :checked_database_row_count, 0),
      checked_filesystem_file_count: map_value(report, :checked_filesystem_file_count, 0),
      invalid_database_rows:
        report |> map_value(:invalid_database_rows, []) |> Enum.map(&normalize_issue/1),
      invalid_filesystem_files:
        report |> map_value(:invalid_filesystem_files, []) |> Enum.map(&normalize_issue/1)
    }
  end

  defp legacy_missing_entries(source_posts, translation_rows, metadata) do
    configured_languages =
      ([Map.get(metadata, :main_language)] ++ Map.get(metadata, :blog_languages, []))
      |> Enum.map(&do_normalize_language/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    existing_languages_by_post =
      Enum.reduce(translation_rows, %{}, fn translation, acc ->
        Map.update(
          acc,
          translation.translation_for,
          MapSet.new([do_normalize_language(translation.language)]),
          &MapSet.put(&1, do_normalize_language(translation.language))
        )
      end)

    source_posts
    |> Enum.filter(&(&1.status == :published and not &1.do_not_translate))
    |> Enum.flat_map(fn post ->
      canonical = canonical_language(post, metadata)
      existing_languages = Map.get(existing_languages_by_post, post.id, MapSet.new())

      configured_languages
      |> Enum.reject(&(&1 == canonical or MapSet.member?(existing_languages, &1)))
      |> Enum.map(&%{post_id: post.id, language: &1})
    end)
    |> Enum.sort_by(&{&1.post_id, &1.language})
  end

  defp legacy_orphan_files(invalid_filesystem_files, project_data_dir) do
    invalid_filesystem_files
    |> Enum.filter(&(Map.get(&1, :issue) == "missing-source-post"))
    |> Enum.map(fn issue ->
      issue
      |> Map.get(:file_path)
      |> relative_project_data_path(project_data_dir)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp legacy_do_not_translate_posts(source_posts) do
    source_posts
    |> Enum.filter(&(&1.status == :published and &1.do_not_translate))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp normalize_issue(issue) when is_map(issue) do
    %{
      issue: map_value(issue, :issue),
      translation_id: blank_to_nil(map_value(issue, :translation_id)),
      translation_for: map_value(issue, :translation_for),
      canonical_language: blank_to_nil(map_value(issue, :canonical_language)),
      translation_language: map_value(issue, :translation_language),
      title: blank_to_nil(map_value(issue, :title)),
      file_path: blank_to_nil(map_value(issue, :file_path))
    }
  end

  defp fix_invalid_database_row(%{issue: "content-in-database", translation_id: translation_id})
       when is_binary(translation_id) do
    case Repo.get(Translation, translation_id) do
      %Translation{} = translation ->
        case Repo.get(Post, translation.translation_for) do
          %Post{} = post ->
            :ok = Translations.publish_translation(post, translation)
            {:flushed, translation.translation_for}

          nil ->
            :noop
        end

      nil ->
        :noop
    end
  end

  defp fix_invalid_database_row(%{
         translation_id: translation_id,
         translation_for: translation_for
       })
       when is_binary(translation_id) do
    case Repo.get(Translation, translation_id) do
      %Translation{} = translation ->
        Repo.delete!(translation)
        {:deleted, translation_for}

      nil ->
        :noop
    end
  end

  defp fix_invalid_database_row(_issue), do: :noop

  defp delete_validation_file(file_path) when file_path in [nil, ""], do: false

  defp delete_validation_file(file_path) do
    case File.rm(file_path) do
      :ok -> true
      {:error, :enoent} -> false
      {:error, _reason} -> false
    end
  end

  defp issue(attrs) do
    %{
      issue: Map.get(attrs, :issue),
      translation_id: Map.get(attrs, :translation_id),
      translation_for: Map.get(attrs, :translation_for),
      canonical_language: Map.get(attrs, :canonical_language),
      translation_language: Map.get(attrs, :translation_language),
      title: Map.get(attrs, :title),
      file_path: Map.get(attrs, :file_path)
    }
  end

  defp issue_sort_key(issue) do
    [
      Map.get(issue, :translation_for),
      Map.get(issue, :translation_id),
      Map.get(issue, :file_path)
    ]
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.join(":")
  end

  defp canonical_language(source_post, metadata) do
    language = do_normalize_language(source_post.language)

    if language == "" do
      do_normalize_language(Map.get(metadata, :main_language))
    else
      language
    end
  end

  defp canonical_language?(source_post, language, metadata) do
    canonical = canonical_language(source_post, metadata)
    canonical != "" and canonical == do_normalize_language(language)
  end

  defp do_normalize_language(nil), do: ""

  defp do_normalize_language(language) do
    language
    |> to_string()
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> hd()
  end

  defp map_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp relative_project_data_path(nil, _project_data_dir), do: nil

  defp relative_project_data_path(file_path, project_data_dir) do
    case Path.relative_to(file_path, project_data_dir) do
      relative_path when relative_path == file_path -> file_path
      relative_path -> relative_path
    end
  end

  defp maybe_put_synced_post(set, post_id) when is_binary(post_id) and post_id != "",
    do: MapSet.put(set, post_id)

  defp maybe_put_synced_post(set, _post_id), do: set

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
