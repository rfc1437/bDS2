defmodule BDS.Rendering.PostRendering do
  @moduledoc false

  import Ecto.Query

  alias BDS.Rendering.Filters
  alias BDS.Rendering.Labels
  alias BDS.Rendering.LinksAndLanguages
  alias BDS.Rendering.Metadata, as: RenderMetadata
  alias BDS.Rendering.RenderContext
  alias BDS.MapUtils
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Repo

  @spec post_assigns(RenderContext.t() | String.t(), map()) :: map()
  def post_assigns(project_id, assigns) when is_binary(project_id) do
    post_assigns(RenderContext.build(project_id), assigns)
  end

  def post_assigns(%RenderContext{} = ctx, assigns) do
    metadata = ctx.metadata

    language = MapUtils.attr(assigns, :language) || metadata.main_language || "en"

    main_language = metadata.main_language || language
    post_record = Map.get(assigns, :_post_record) || load_post_record(ctx, assigns)
    canonical_post = canonical_post_record(ctx, post_record)
    post_id = canonical_post_id(post_record, assigns)
    post_categories = record_list(post_record, :categories)
    post_tags = record_list(post_record, :tags)

    raw_content = MapUtils.attr(assigns, :content)
    rendered_content = cached_post_content(ctx, raw_content, language, post_id)

    incoming_links = RenderContext.link_contexts(ctx, post_id, :incoming)
    outgoing_links = RenderContext.link_contexts(ctx, post_id, :outgoing)

    post_assigns =
      assigns
      |> Map.put(:content, rendered_content)
      |> Map.put(:raw_content, raw_content)

    %{
      language: language,
      language_prefix:
        assign_override(
          assigns,
          :language_prefix,
          "language_prefix",
          LinksAndLanguages.language_prefix(language, main_language)
        ),
      page_title:
        Map.get(
          assigns,
          :page_title,
          MapUtils.attr(assigns, :title)
        ),
      pico_stylesheet_href:
        assign_override(
          assigns,
          :pico_stylesheet_href,
          "pico_stylesheet_href",
          RenderMetadata.default_pico_stylesheet_href(metadata.pico_theme)
        ),
      html_theme_attribute:
        assign_override(assigns, :html_theme_attribute, "html_theme_attribute", nil),
      blog_languages: RenderMetadata.blog_languages(metadata, language),
      alternate_links:
        RenderMetadata.alternate_links_from(
          canonical_post,
          ctx_translations(ctx, canonical_post),
          main_language
        ),
      menu_items: ctx.menu_items,
      calendar_initial_year: RenderMetadata.calendar_initial_year(post_record),
      calendar_initial_month: RenderMetadata.calendar_initial_month(post_record),
      post_categories: post_categories,
      post_tags: post_tags,
      tag_color_by_name: ctx.tag_color_by_name,
      backlinks: RenderMetadata.backlinks(incoming_links),
      canonical_post_path_by_slug: ctx.canonical_post_paths,
      canonical_media_path_by_source_path: ctx.canonical_media_paths,
      post_data_json_by_id:
        post_data_json(ctx, post_assigns, post_record, incoming_links, outgoing_links),
      post:
        build_post_context(ctx, post_assigns, post_record, incoming_links, outgoing_links),
      labels: Labels.for_language(language)
    }
  end

  @doc """
  Render post markdown through the context's canonical URL maps, memoizing by
  content, language, and post id so the same content is only rendered once per
  full-site render (posts appear on many list/archive pages).
  """
  @spec cached_post_content(RenderContext.t(), term(), String.t(), term()) :: String.t()
  def cached_post_content(%RenderContext{} = ctx, content, language, post_id \\ nil) do
    raw = to_string(content || "")

    RenderContext.memoize(
      ctx,
      {:rendered_markdown, :erlang.md5(raw), language, post_id},
      fn ->
        render_post_content(
          raw,
          ctx.canonical_post_paths,
          ctx.canonical_media_paths,
          language,
          ctx.template_context,
          post_id
        )
      end
    )
  end

  defp ctx_translations(_ctx, nil), do: []

  defp ctx_translations(%RenderContext{} = ctx, %Post{id: post_id}),
    do: Map.get(ctx.translations_by_post, post_id, [])

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

  defp load_post_record(%RenderContext{} = ctx, assigns) do
    case MapUtils.attr(assigns, :id) do
      nil -> nil
      post_id -> Map.get(ctx.record_by_id, post_id)
    end
  end

  defp canonical_post_record(%RenderContext{} = ctx, %Translation{translation_for: post_id}) do
    case Map.get(ctx.record_by_id, post_id) do
      %Post{} = post -> post
      _other -> nil
    end
  end

  defp canonical_post_record(_ctx, %Post{} = post), do: post
  defp canonical_post_record(_ctx, _other), do: nil

  defp canonical_post_id(%Translation{translation_for: post_id}, _assigns), do: post_id
  defp canonical_post_id(%Post{id: post_id}, _assigns), do: post_id
  defp canonical_post_id(_post_record, assigns), do: MapUtils.attr(assigns, :id)

  defp post_data_json(ctx, assigns, post_record, incoming_links, outgoing_links) do
    id = MapUtils.attr(assigns, :id)

    if is_binary(id) do
      %{
        id =>
          post_data_json_value(
            build_post_context(ctx, assigns, post_record, incoming_links, outgoing_links)
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

  defp build_post_context(ctx, assigns, post_record, incoming_links, outgoing_links) do
    %{
      id: MapUtils.attr(assigns, :id),
      slug: MapUtils.attr(assigns, :slug),
      title: MapUtils.attr(assigns, :title),
      content: MapUtils.attr(assigns, :content),
      raw_content: MapUtils.attr(assigns, :raw_content),
      project_id: MapUtils.attr(assigns, :project_id) || record_value(post_record, :project_id),
      excerpt:
        Map.get(
          assigns,
          :excerpt,
          record_value(post_record, :excerpt)
        ),
      author: record_value(post_record, :author),
      language:
        Map.get(
          assigns,
          :language,
          record_value(post_record, :language)
        ),
      show_title: true,
      published_at: record_value(post_record, :published_at),
      created_at: record_value(post_record, :created_at),
      updated_at: record_value(post_record, :updated_at),
      tags: record_list(post_record, :tags),
      categories: record_list(post_record, :categories),
      template_slug:
        Map.get(
          post_record || %{},
          :template_slug,
          MapUtils.attr(assigns, :template_slug)
        ),
      do_not_translate: record_value(post_record, :do_not_translate, false),
      linked_media: linked_media_images(ctx, assigns),
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

  defp linked_media_images(%RenderContext{} = ctx, assigns) do
    post_id = MapUtils.attr(assigns, :id)

    if is_binary(post_id) do
      Map.get(ctx.linked_media_by_post, post_id, [])
    else
      []
    end
  end

  defp assign_override(assigns, atom_key, string_key, default) do
    Map.get(assigns, atom_key, Map.get(assigns, string_key, default))
  end

  defp record_value(post_record, key, default \\ nil) do
    Map.get(post_record || %{}, key, default)
  end

  defp record_list(post_record, key), do: record_value(post_record, key, []) || []
end
