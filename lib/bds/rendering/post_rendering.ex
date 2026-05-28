defmodule BDS.Rendering.PostRendering do
  @moduledoc false

  import Ecto.Query

  alias BDS.Rendering.Filters
  alias BDS.Rendering.Labels
  alias BDS.Rendering.LinksAndLanguages
  alias BDS.Rendering.Metadata, as: RenderMetadata
  alias BDS.Rendering.TemplateSelection
  alias BDS.MapUtils
  alias BDS.Posts.Post
  alias BDS.Posts.PostMedia
  alias BDS.Posts.Translation
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Repo

  @spec post_assigns(String.t(), map()) :: map()
  def post_assigns(project_id, assigns) do
    metadata = RenderMetadata.project_metadata(project_id)
    template_context = TemplateSelection.template_render_context(project_id)

    language = MapUtils.attr(assigns, :language, metadata.main_language || "en")

    main_language = metadata.main_language || language
    post_record = Map.get(assigns, :_post_record) || load_post_record(assigns)
    canonical_post = canonical_post_record(post_record)
    post_id = canonical_post_id(post_record, assigns)
    post_categories = Map.get(post_record || %{}, :categories, []) || []
    post_tags = Map.get(post_record || %{}, :tags, []) || []

    canonical_post_paths =
      LinksAndLanguages.canonical_post_path_by_slug(project_id, main_language)

    canonical_media_paths = LinksAndLanguages.canonical_media_path_by_source_path(project_id)
    raw_content = MapUtils.attr(assigns, :content)

    rendered_content =
      render_post_content(
        raw_content,
        canonical_post_paths,
        canonical_media_paths,
        language,
        template_context,
        post_id
      )

    incoming_links =
      LinksAndLanguages.link_contexts(project_id, post_id, :incoming, main_language)

    outgoing_links =
      LinksAndLanguages.link_contexts(project_id, post_id, :outgoing, main_language)

    post_assigns =
      assigns
      |> Map.put(:content, rendered_content)
      |> Map.put(:raw_content, raw_content)

    %{
      language: language,
      language_prefix:
        Map.get(
          assigns,
          :language_prefix,
          Map.get(
            assigns,
            "language_prefix",
            LinksAndLanguages.language_prefix(language, main_language)
          )
        ),
      page_title:
        Map.get(
          assigns,
          :page_title,
          MapUtils.attr(assigns, :title)
        ),
      pico_stylesheet_href:
        Map.get(
          assigns,
          :pico_stylesheet_href,
          Map.get(
            assigns,
            "pico_stylesheet_href",
            RenderMetadata.default_pico_stylesheet_href(metadata.pico_theme)
          )
        ),
      html_theme_attribute:
        Map.get(
          assigns,
          :html_theme_attribute,
          Map.get(assigns, "html_theme_attribute")
        ),
      blog_languages: RenderMetadata.blog_languages(metadata, language),
      alternate_links: RenderMetadata.alternate_links(canonical_post, project_id, main_language),
      menu_items: RenderMetadata.menu_items(project_id),
      calendar_initial_year: RenderMetadata.calendar_initial_year(post_record),
      calendar_initial_month: RenderMetadata.calendar_initial_month(post_record),
      post_categories: post_categories,
      post_tags: post_tags,
      tag_color_by_name: RenderMetadata.tag_color_by_name(project_id),
      backlinks: RenderMetadata.backlinks(incoming_links),
      canonical_post_path_by_slug: canonical_post_paths,
      canonical_media_path_by_source_path: canonical_media_paths,
      post_data_json_by_id: post_data_json(post_assigns, post_record),
      post: build_post_context(post_assigns, post_record, incoming_links, outgoing_links),
      labels: Labels.for_language(language)
    }
  end

  @spec load_post_record(map()) :: Post.t() | Translation.t() | nil
  def load_post_record(assigns) do
    case MapUtils.attr(assigns, :id) do
      nil -> nil
      post_id -> Repo.get(Post, post_id) || Repo.get(Translation, post_id)
    end
  end

  @spec load_post_records_batch([String.t()]) :: %{String.t() => Post.t() | Translation.t() | nil}
  def load_post_records_batch([]), do: %{}

  def load_post_records_batch(post_ids) when is_list(post_ids) do
    posts =
      Repo.all(from p in Post, where: p.id in ^post_ids)
      |> Enum.map(&{&1.id, &1})
      |> Map.new()

    missing_ids = Enum.reject(post_ids, &Map.has_key?(posts, &1))

    translations =
      if Enum.empty?(missing_ids) do
        %{}
      else
        Repo.all(from t in Translation, where: t.id in ^missing_ids)
        |> Enum.map(&{&1.id, &1})
        |> Map.new()
      end

    missing_after_translations = Enum.reject(missing_ids, &Map.has_key?(translations, &1))

    nil_entries =
      missing_after_translations
      |> Enum.map(&{&1, nil})
      |> Map.new()

    Map.merge(posts, Map.merge(translations, nil_entries))
  end

  defp canonical_post_record(%Translation{translation_for: post_id}), do: Repo.get(Post, post_id)
  defp canonical_post_record(%Post{} = post), do: post
  defp canonical_post_record(_other), do: nil

  defp canonical_post_id(%Translation{translation_for: post_id}, _assigns), do: post_id
  defp canonical_post_id(%Post{id: post_id}, _assigns), do: post_id
  defp canonical_post_id(_post_record, assigns), do: MapUtils.attr(assigns, :id)

  defp post_data_json(assigns, post_record) do
    id = MapUtils.attr(assigns, :id)

    if is_binary(id) do
      incoming_links =
        LinksAndLanguages.link_contexts(
          Map.get(post_record || %{}, :project_id),
          canonical_post_id(post_record, assigns),
          :incoming,
          Map.get(post_record || %{}, :language)
        )

      outgoing_links =
        LinksAndLanguages.link_contexts(
          Map.get(post_record || %{}, :project_id),
          canonical_post_id(post_record, assigns),
          :outgoing,
          Map.get(post_record || %{}, :language)
        )

      %{
        id =>
          post_data_json_value(
            build_post_context(assigns, post_record, incoming_links, outgoing_links)
          )
      }
    else
      %{}
    end
  end

  @spec post_data_json_value(map()) :: String.t()
  def post_data_json_value(post_context) do
    case Jason.encode(%{
           id: Map.get(post_context, :id),
           title: Map.get(post_context, :title),
           slug: Map.get(post_context, :slug),
           excerpt: Map.get(post_context, :excerpt),
           author: Map.get(post_context, :author),
           language: Map.get(post_context, :language),
           published_at: Map.get(post_context, :published_at),
           created_at: Map.get(post_context, :created_at),
           updated_at: Map.get(post_context, :updated_at),
           tags: Map.get(post_context, :tags, []),
           categories: Map.get(post_context, :categories, [])
         }) do
      {:ok, json} -> json
      {:error, _reason} -> "{}"
    end
  end

  defp build_post_context(assigns, post_record, incoming_links, outgoing_links) do
    %{
      id: MapUtils.attr(assigns, :id),
      slug: MapUtils.attr(assigns, :slug),
      title: MapUtils.attr(assigns, :title),
      content: MapUtils.attr(assigns, :content),
      raw_content: MapUtils.attr(assigns, :raw_content),
      project_id: MapUtils.attr(assigns, :project_id) || Map.get(post_record || %{}, :project_id),
      excerpt:
        Map.get(
          assigns,
          :excerpt,
          Map.get(post_record || %{}, :excerpt)
        ),
      author: Map.get(post_record || %{}, :author),
      language:
        Map.get(
          assigns,
          :language,
          Map.get(post_record || %{}, :language)
        ),
      show_title: true,
      published_at: Map.get(post_record || %{}, :published_at),
      created_at: Map.get(post_record || %{}, :created_at),
      updated_at: Map.get(post_record || %{}, :updated_at),
      tags: Map.get(post_record || %{}, :tags, []) || [],
      categories: Map.get(post_record || %{}, :categories, []) || [],
      template_slug:
        Map.get(
          post_record || %{},
          :template_slug,
          MapUtils.attr(assigns, :template_slug)
        ),
      do_not_translate: Map.get(post_record || %{}, :do_not_translate, false),
      linked_media: linked_media_images(assigns),
      outgoing_links: outgoing_links,
      incoming_links: incoming_links
    }
  end

  @spec render_post_content(
          String.t() | nil,
          map(),
          map(),
          String.t(),
          Liquex.Context.t(),
          term()
        ) :: String.t()
  def render_post_content(
        content,
        canonical_post_paths,
        canonical_media_paths,
        language,
        template_context,
        post_id \\ nil
      ) do
    Filters.render_markdown(
      content,
      canonical_post_paths,
      canonical_media_paths,
      language,
      template_context,
      post_id
    )
  end

  defp linked_media_images(assigns) do
    post_id = MapUtils.attr(assigns, :id)

    if is_binary(post_id) do
      Repo.all(
        from pm in PostMedia,
          join: m in MediaRecord,
          on: pm.media_id == m.id,
          where: pm.post_id == ^post_id,
          where: like(m.mime_type, "image/%"),
          order_by: [asc: pm.sort_order, asc: pm.media_id],
          select: m
      )
    else
      []
    end
  end
end
