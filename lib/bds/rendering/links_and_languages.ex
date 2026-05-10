defmodule BDS.Rendering.LinksAndLanguages do
  @moduledoc false

  import Ecto.Query

  alias BDS.Media.Media, as: MediaAsset
  alias BDS.Persistence
  alias BDS.PostLinks
  alias BDS.Posts.Post
  alias BDS.Repo

  @spec canonical_post_path_by_slug(String.t(), String.t()) :: %{String.t() => String.t()}
  def canonical_post_path_by_slug(project_id, main_language) do
    posts =
      Repo.all(
        from post in Post, where: post.project_id == ^project_id and post.status == :published
      )

    translations =
      Repo.all(
        from translation in BDS.Posts.Translation,
          where: translation.project_id == ^project_id and translation.status == :published
      )

    post_by_id = Map.new(posts, fn post -> {post.id, post} end)

    post_paths =
      Enum.into(posts, %{}, fn post ->
        {post.slug, post_path(post, nil)}
      end)

    Enum.reduce(translations, post_paths, fn translation, acc ->
      case Map.get(post_by_id, translation.translation_for) do
        nil -> acc
        post -> Map.put(acc, post.slug, post_path(post, translation.language, main_language))
      end
    end)
  end

  @spec canonical_media_path_by_source_path(String.t()) :: %{String.t() => String.t()}
  def canonical_media_path_by_source_path(project_id) do
    Repo.all(from media in MediaAsset, where: media.project_id == ^project_id)
    |> Enum.reduce(%{}, fn media, acc ->
      datetime = Persistence.from_unix_ms!(media.created_at)

      source_key =
        Path.join([
          "media",
          Integer.to_string(datetime.year),
          String.pad_leading(Integer.to_string(datetime.month), 2, "0"),
          media.original_name
        ])
        |> String.downcase()

      Map.put(acc, source_key, Path.join("/", media.file_path))
    end)
  end

  @spec post_path(map(), String.t() | nil) :: String.t()
  def post_path(post, language_prefix)
      when is_binary(language_prefix) and language_prefix != "" do
    String.trim_trailing(language_prefix, "/") <> post_path(post, nil)
  end

  def post_path(post, ""), do: post_path(post, nil)

  def post_path(post, nil) do
    datetime = Persistence.from_unix_ms!(post.created_at)

    Path.join([
      "/",
      Integer.to_string(datetime.year),
      String.pad_leading(Integer.to_string(datetime.month), 2, "0"),
      String.pad_leading(Integer.to_string(datetime.day), 2, "0"),
      post.slug
    ]) <> "/"
  end

  @spec post_path(map(), String.t() | nil, String.t()) :: String.t()
  def post_path(post, language, main_language) do
    prefix = language_prefix(language, main_language)
    post_path(post, prefix)
  end

  @spec link_contexts(String.t() | nil, String.t() | nil, :incoming | :outgoing, String.t()) :: [
          map()
        ]
  def link_contexts(_project_id, nil, _direction, _main_language), do: []

  def link_contexts(project_id, post_id, :incoming, main_language) do
    PostLinks.list_incoming_links(post_id)
    |> Enum.map(&link_context(project_id, &1, :incoming, main_language))
    |> Enum.reject(&is_nil/1)
  end

  def link_contexts(project_id, post_id, :outgoing, main_language) do
    PostLinks.list_outgoing_links(post_id)
    |> Enum.map(&link_context(project_id, &1, :outgoing, main_language))
    |> Enum.reject(&is_nil/1)
  end

  defp link_context(_project_id, link, direction, main_language) do
    linked_post_id =
      case direction do
        :incoming -> link.source_post_id
        :outgoing -> link.target_post_id
      end

    case Repo.get(Post, linked_post_id) do
      nil ->
        nil

      linked_post ->
        %{
          href: post_path(linked_post, nil),
          title: linked_post.title,
          display_slug: linked_post.slug,
          language: normalize_language(linked_post.language, main_language)
        }
    end
  end

  @spec language_prefix(String.t() | nil, String.t()) :: String.t()
  def language_prefix(language, main_language) when language == main_language, do: ""
  def language_prefix(nil, _main_language), do: ""
  def language_prefix(language, _main_language), do: "/#{language}"

  @spec normalize_language(String.t() | nil, String.t()) :: String.t()
  def normalize_language(nil, fallback), do: fallback
  def normalize_language("", fallback), do: fallback

  def normalize_language(language, _fallback) do
    language
    |> to_string()
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> hd()
  end
end
