defmodule BDS.Scripting.Capabilities.Media do
  @moduledoc false

  import Ecto.Query
  import BDS.Scripting.Capabilities.Util

  alias BDS.Media
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Media.Translation, as: MediaTranslation
  alias BDS.Repo
  alias BDS.Search

  def import_media(project_id, attrs) do
    attrs
    |> normalize_map()
    |> normalize_media_attrs()
    |> Map.put("project_id", project_id)
    |> Media.import_media()
    |> unwrap_result()
  end

  def update_media(project_id, media_id, attrs) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} ->
        Media.update_media(media_id, attrs |> normalize_map() |> normalize_media_attrs())
        |> unwrap_result()

      _other ->
        nil
    end
  end

  def delete_media(project_id, media_id) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} -> boolean_result(Media.delete_media(media_id))
      _other -> false
    end
  end

  def load_media(project_id, media_id) do
    fetch_media(project_id, media_id)
    |> sanitize_nilable()
  end

  def list_media(project_id) do
    Repo.all(
      from(media in MediaRecord,
        where: media.project_id == ^project_id,
        order_by: [asc: media.created_at]
      )
    )
    |> Enum.map(&sanitize/1)
  end

  def load_media_translation(project_id, media_id, language) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{id: id} ->
        Repo.one(
          from(translation in MediaTranslation,
            where:
              translation.translation_for == ^id and
                translation.language == ^(string_or_nil(language) || ""),
            limit: 1
          )
        )
        |> sanitize_nilable()

      _other ->
        nil
    end
  end

  def list_media_translations(project_id, media_id) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{id: id} ->
        Repo.all(
          from(translation in MediaTranslation,
            where: translation.translation_for == ^id,
            order_by: [asc: translation.language]
          )
        )
        |> Enum.map(&sanitize/1)

      _other ->
        []
    end
  end

  def upsert_media_translation(project_id, media_id, language, attrs) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} ->
        Media.upsert_media_translation(
          media_id,
          string_or_nil(language) || "",
          normalize_media_translation_attrs(normalize_map(attrs))
        )
        |> unwrap_result()

      _other ->
        nil
    end
  end

  def delete_media_translation(project_id, media_id, language) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} ->
        case Media.delete_media_translation(media_id, string_or_nil(language) || "") do
          {:ok, deleted?} -> deleted?
          {:error, _reason} -> false
        end

      _other ->
        false
    end
  end

  def filter_media(project_id, filters) do
    filters = normalize_map(filters)

    list_media(project_id)
    |> Enum.filter(fn media -> media_matches_filters?(media, filters) end)
  end

  def media_counts_by_year_month(project_id) do
    list_media(project_id)
    |> Enum.reduce(%{}, fn media, acc ->
      datetime = media_datetime(media)
      key = {datetime.year, datetime.month}
      Map.update(acc, key, 1, &(&1 + 1))
    end)
    |> Enum.map(fn {{year, month}, count} ->
      %{"year" => year, "month" => month, "count" => count}
    end)
    |> Enum.sort_by(fn row -> {-row["year"], -row["month"]} end)
  end

  def media_file_path(project_id, media_id) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} = media -> Path.join(project_path(project_id), media.file_path)
      _other -> nil
    end
  end

  def media_tags(project_id), do: media_tags_with_counts(project_id) |> Enum.map(& &1["tag"])

  def media_tags_with_counts(project_id) do
    Repo.all(
      from(media in MediaRecord,
        where: media.project_id == ^project_id,
        order_by: [asc: media.created_at]
      )
    )
    |> Enum.flat_map(&(&1.tags || []))
    |> Enum.reduce(%{}, fn tag, acc -> Map.update(acc, tag, 1, &(&1 + 1)) end)
    |> Enum.map(fn {tag, count} -> %{"tag" => tag, "count" => count} end)
    |> Enum.sort_by(fn row -> {-row["count"], String.downcase(row["tag"])} end)
  end

  def media_thumbnail(project_id, media_id, size) do
    with %MediaRecord{} = media <- fetch_media(project_id, media_id),
         relative_path <- Media.thumbnail_paths(media)[thumbnail_size(size)],
         absolute_path <- Path.join(project_path(project_id), relative_path),
         true <- File.exists?(absolute_path),
         {:ok, binary} <- File.read(absolute_path) do
      "data:#{thumbnail_mime(absolute_path)};base64," <> Base.encode64(binary)
    else
      _other -> nil
    end
  end

  def media_url(project_id, media_id) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} = media -> "/" <> String.trim_leading(media.file_path, "/")
      _other -> nil
    end
  end

  def rebuild_media_from_files(project_id) do
    project_id
    |> Media.rebuild_media_from_files()
    |> unwrap_result(fn media -> Enum.map(media, &sanitize/1) end)
  end

  def regenerate_missing_thumbnails(project_id) do
    Media.regenerate_missing_thumbnails(project_id)
    |> sanitize()
  end

  def regenerate_media_thumbnails(project_id, media_id) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} = media ->
        case Media.regenerate_thumbnails(media.id) do
          {:ok, _media} ->
            Media.thumbnail_paths(media)
            |> Enum.map(fn {size, relative_path} ->
              {to_string(size), Path.join(project_path(project_id), relative_path)}
            end)
            |> Map.new()

          {:error, _reason} ->
            nil
        end

      _other ->
        nil
    end
  end

  def replace_media_file(project_id, media_id, source_path) do
    case fetch_media(project_id, media_id) do
      %MediaRecord{} ->
        Media.replace_media_file(media_id, string_or_nil(source_path) || "")
        |> unwrap_result()

      _other ->
        nil
    end
  end

  def search_media(project_id, query) do
    project_id
    |> Search.search_media(string_or_nil(query) || "")
    |> unwrap_result(fn %{media: media} -> Enum.map(media, &sanitize/1) end)
  end

  def fetch_media(project_id, media_id) do
    Repo.one(
      from(media in MediaRecord,
        where: media.project_id == ^project_id and media.id == ^(string_or_nil(media_id) || ""),
        limit: 1
      )
    )
  end

  def normalize_media_attrs(attrs) do
    attrs
    |> maybe_put_normalized_list("tags")
  end

  def normalize_media_translation_attrs(attrs) do
    attrs
    |> Map.take(["title", "alt", "caption"])
  end

  def media_matches_filters?(media, filters) do
    created_at = media_datetime(media)
    tags = Map.get(media, "tags", [])
    language = Map.get(media, "language")

    matches_year =
      compare_optional(Map.get(filters, "year"), fn year ->
        created_at.year == integer_or_default(year, created_at.year)
      end)

    matches_month =
      compare_optional(Map.get(filters, "month"), fn month ->
        created_at.month == integer_or_default(month, created_at.month)
      end)

    matches_language =
      compare_optional(blank_to_nil(Map.get(filters, "language")), fn value ->
        language == value
      end)

    matches_tags =
      compare_optional(Map.get(filters, "tags"), fn required_tags ->
        Enum.all?(normalize_string_list(required_tags), &(&1 in tags))
      end)

    matches_from =
      compare_optional(
        parse_datetime(Map.get(filters, "from") || Map.get(filters, "start_date")),
        fn from_dt -> DateTime.compare(created_at, from_dt) != :lt end
      )

    matches_to =
      compare_optional(
        parse_datetime(Map.get(filters, "to") || Map.get(filters, "end_date")),
        fn to_dt -> DateTime.compare(created_at, to_dt) != :gt end
      )

    matches_year and matches_month and matches_language and matches_tags and matches_from and
      matches_to
  end

  def media_datetime(media) do
    media
    |> Map.get("created_at")
    |> case do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _other -> DateTime.utc_now()
        end

      value when is_integer(value) ->
        DateTime.from_unix!(value, :millisecond)

      _other ->
        DateTime.utc_now()
    end
  end
end
