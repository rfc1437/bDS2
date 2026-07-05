defmodule BDS.Rendering.Metadata do
  @moduledoc false

  import Ecto.Query

  alias BDS.I18n
  alias BDS.Menu
  alias BDS.Metadata, as: ProjectMetadata
  alias BDS.Persistence
  alias BDS.PreviewAssets
  alias BDS.Rendering.LinksAndLanguages
  alias BDS.Repo
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Tags.Tag

  @menu_item_path_segments %{
    page: [],
    category_archive: ["category"]
  }

  @spec project_metadata(String.t()) :: map()
  def project_metadata(project_id) do
    {:ok, metadata} = ProjectMetadata.get_project_metadata(project_id)
    metadata
  end

  @spec menu_items(String.t()) :: [map()]
  def menu_items(project_id) do
    {:ok, %{items: items}} = Menu.get_menu(project_id)
    template_menu_items(items)
  end

  @spec menu_items_from_raw([map()]) :: [map()]
  def menu_items_from_raw(items) when is_list(items) do
    template_menu_items(items)
  end

  defp template_menu_items(items), do: Enum.map(items, &to_template_menu_item/1)

  defp to_template_menu_item(item) do
    kind = Map.get(item, :kind)
    children = template_menu_items(Map.get(item, :children, []))

    %{
      title: Map.get(item, :label, ""),
      href: menu_item_href(item),
      has_children: children != [],
      children: children,
      kind: kind
    }
  end

  defp menu_item_href(%{kind: :home}), do: "/"

  defp menu_item_href(%{kind: kind, slug: slug}) when is_binary(slug) and slug != "" do
    case Map.get(@menu_item_path_segments, kind) do
      nil -> "#"
      path_segments -> "/" <> Path.join(path_segments ++ [URI.encode(slug)]) <> "/"
    end
  end

  defp menu_item_href(_item), do: "#"

  @spec blog_languages(map(), String.t()) :: [map()]
  def blog_languages(metadata, current_language) do
    ([metadata.main_language] ++ (metadata.blog_languages || []))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.map(fn language ->
      normalized = I18n.normalize_language(language)

      href_prefix =
        LinksAndLanguages.language_prefix(normalized, metadata.main_language || current_language)

      %{
        code: normalized,
        flag: I18n.flag(normalized),
        href: href_for_language(href_prefix),
        href_prefix: href_prefix,
        is_current: normalized == I18n.normalize_language(current_language)
      }
    end)
  end

  @spec tag_color_by_name(String.t()) :: %{String.t() => String.t() | nil}
  def tag_color_by_name(project_id) do
    Repo.all(from tag in Tag, where: tag.project_id == ^project_id, select: {tag.name, tag.color})
    |> Enum.into(%{}, fn {name, color} -> {name, color} end)
  end

  @spec alternate_links(Post.t() | nil, String.t(), String.t()) :: [map()]
  def alternate_links(nil, _project_id, _main_language), do: []

  def alternate_links(%Post{} = post, project_id, main_language) do
    translations =
      Repo.all(
        from translation in Translation,
          where:
            translation.project_id == ^project_id and
              translation.translation_for == ^post.id and
              translation.status == :published,
          order_by: [asc: translation.language]
      )

    alternate_links_from(post, translations, main_language)
  end

  @spec alternate_links_from(Post.t() | nil, [Translation.t()], String.t()) :: [map()]
  def alternate_links_from(nil, _translations, _main_language), do: []

  def alternate_links_from(%Post{} = post, translations, main_language) do
    [
      %{
        href: LinksAndLanguages.post_path(post, nil),
        hreflang: LinksAndLanguages.normalize_language(post.language, main_language)
      }
    ] ++
      Enum.map(translations, fn translation ->
        %{
          href: LinksAndLanguages.post_path(post, translation.language, main_language),
          hreflang: translation.language
        }
      end)
  end

  @spec backlinks([map()]) :: [map()]
  def backlinks(incoming_links) do
    Enum.map(incoming_links, fn link ->
      %{path: link.href, display_slug: link.display_slug, title: link.title}
    end)
  end

  @spec default_pico_stylesheet_href(String.t() | nil) :: String.t()
  def default_pico_stylesheet_href(theme), do: PreviewAssets.stylesheet_href(theme)

  @spec href_for_language(String.t()) :: String.t()
  def href_for_language(""), do: "/"
  def href_for_language(prefix), do: String.trim_trailing(prefix, "/") <> "/"

  @spec calendar_initial_year(map() | nil) :: integer() | nil
  def calendar_initial_year(%{created_at: created_at}) when is_integer(created_at),
    do: Persistence.from_unix_ms!(created_at).year

  def calendar_initial_year(_post), do: nil

  @spec calendar_initial_month(map() | nil) :: integer() | nil
  def calendar_initial_month(%{created_at: created_at}) when is_integer(created_at),
    do: Persistence.from_unix_ms!(created_at).month

  def calendar_initial_month(_post), do: nil
end
