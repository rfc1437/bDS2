defmodule BDS.Rendering.RenderContext do
  @moduledoc """
  Load-once bundle of everything page rendering needs.

  Mirrors the old app's generation worker design: all project-wide data
  (metadata, menu, canonical URL maps, link graphs, media, template roots) is
  loaded up front in a handful of queries, and per-page rendering then works
  from immutable in-memory data instead of re-querying the database and
  re-reading config files for every page. An ETS-backed `memoize/3` cache holds
  parsed template ASTs, post bodies, and rendered markdown for the lifetime of
  the context.

  The ETS cache table is owned by the process that calls `build/1` and is
  reclaimed automatically when that process exits, so a context must not
  outlive its creator.
  """

  import Ecto.Query

  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Metadata, as: ProjectMetadata
  alias BDS.Posts.Link
  alias BDS.Posts.Post
  alias BDS.Posts.PostMedia
  alias BDS.Posts.Translation
  alias BDS.Projects
  alias BDS.Rendering.FileSystem
  alias BDS.Rendering.Filters
  alias BDS.Rendering.LinksAndLanguages
  alias BDS.Rendering.Metadata, as: RenderMetadata
  alias BDS.Repo
  alias BDS.StarterTemplates
  alias BDS.Tags.Tag

  defstruct [
    :project,
    :project_id,
    :project_data_dir,
    :metadata,
    :main_language,
    :menu_items,
    :tag_color_by_name,
    :canonical_post_paths,
    :canonical_media_paths,
    :file_system,
    :template_context,
    :record_by_id,
    :incoming_links_by_post,
    :outgoing_links_by_post,
    :translations_by_post,
    :linked_media_by_post,
    :tag_template_slug_by_name,
    :cache
  ]

  @type t :: %__MODULE__{}

  @spec build(String.t()) :: t()
  def build(project_id) when is_binary(project_id) do
    project = Projects.get_project!(project_id)
    {:ok, metadata} = ProjectMetadata.get_project_metadata(project_id)
    main_language = metadata.main_language || "en"

    posts = Repo.all(from post in Post, where: post.project_id == ^project_id)
    post_by_id = Map.new(posts, &{&1.id, &1})

    translations =
      Repo.all(from translation in Translation, where: translation.project_id == ^project_id)

    {incoming_links_by_post, outgoing_links_by_post} =
      build_link_context_maps(project_id, post_by_id, main_language)

    file_system = FileSystem.new(StarterTemplates.template_roots(project))

    %__MODULE__{
      project: project,
      project_id: project_id,
      project_data_dir: Projects.project_data_dir(project),
      metadata: metadata,
      main_language: main_language,
      menu_items: RenderMetadata.menu_items(project_id),
      tag_color_by_name: RenderMetadata.tag_color_by_name(project_id),
      canonical_post_paths:
        LinksAndLanguages.canonical_post_path_by_slug(project_id, main_language),
      canonical_media_paths: LinksAndLanguages.canonical_media_path_by_source_path(project_id),
      file_system: file_system,
      template_context:
        Liquex.Context.new(%{},
          static_environment: %{},
          filter_module: Filters,
          file_system: file_system
        )
        |> put_context_project_id(project_id),
      record_by_id: Map.merge(Map.new(translations, &{&1.id, &1}), post_by_id),
      incoming_links_by_post: incoming_links_by_post,
      outgoing_links_by_post: outgoing_links_by_post,
      translations_by_post: build_translations_by_post(translations),
      linked_media_by_post: build_linked_media_by_post(project_id),
      tag_template_slug_by_name: build_tag_template_slugs(project_id),
      cache: :ets.new(:bds_render_context_cache, [:set, :public, {:read_concurrency, true}])
    }
  end

  @doc """
  Return the cached value for `key`, computing and caching it with `fun` on the
  first call. Single-flight: concurrent first calls for the same key compute
  exactly once — later callers wait for the winner instead of duplicating the
  work (template parses, file reads) and its queries.
  """
  @spec memoize(t(), term(), (-> value)) :: value when value: term()
  def memoize(%__MODULE__{cache: cache} = ctx, key, fun) when is_function(fun, 0) do
    case :ets.lookup(cache, key) do
      [{^key, value}] -> value
      [] -> compute_memoized(ctx, key, fun)
    end
  end

  defp compute_memoized(%__MODULE__{cache: cache} = ctx, key, fun) do
    lock_key = {:memoize_lock, key}

    if :ets.insert_new(cache, {lock_key, self()}) do
      try do
        value = fun.()
        true = :ets.insert(cache, {key, value})
        value
      after
        :ets.delete(cache, lock_key)
      end
    else
      # Another process is computing this key; poll until its value lands (or
      # its lock disappears because it crashed, in which case we take over).
      Process.sleep(2)
      memoize(ctx, key, fun)
    end
  end

  @spec link_contexts(t(), String.t() | nil, :incoming | :outgoing) :: [map()]
  def link_contexts(_ctx, nil, _direction), do: []

  def link_contexts(%__MODULE__{} = ctx, post_id, :incoming),
    do: Map.get(ctx.incoming_links_by_post, post_id, [])

  def link_contexts(%__MODULE__{} = ctx, post_id, :outgoing),
    do: Map.get(ctx.outgoing_links_by_post, post_id, [])

  ## --- internals -----------------------------------------------------------

  # Stash the project id in the context's private map (not exposed to templates)
  # so built-in macros (photo archive, tag cloud, gallery) can resolve their
  # project-scoped data even when rendered outside a full page context.
  defp put_context_project_id(%Liquex.Context{private: private} = context, project_id) do
    %{context | private: Map.put(private, :project_id, project_id)}
  end

  defp build_link_context_maps(project_id, post_by_id, main_language) do
    links =
      Repo.all(
        from link in Link,
          join: source in Post,
          on: link.source_post_id == source.id,
          where: source.project_id == ^project_id,
          order_by: [asc: link.created_at]
      )

    incoming =
      links
      |> Enum.group_by(& &1.target_post_id)
      |> Map.new(fn {post_id, post_links} ->
        {post_id, link_contexts_for(post_links, & &1.source_post_id, post_by_id, main_language)}
      end)

    outgoing =
      links
      |> Enum.group_by(& &1.source_post_id)
      |> Map.new(fn {post_id, post_links} ->
        {post_id, link_contexts_for(post_links, & &1.target_post_id, post_by_id, main_language)}
      end)

    {incoming, outgoing}
  end

  defp link_contexts_for(links, linked_id_fun, post_by_id, main_language) do
    links
    |> Enum.map(fn link ->
      case Map.get(post_by_id, linked_id_fun.(link)) do
        nil -> nil
        linked_post -> LinksAndLanguages.link_context_for_post(linked_post, main_language)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp build_translations_by_post(translations) do
    translations
    |> Enum.filter(&(&1.status == :published))
    |> Enum.sort_by(& &1.language)
    |> Enum.group_by(& &1.translation_for)
  end

  defp build_linked_media_by_post(project_id) do
    Repo.all(
      from post_media in PostMedia,
        join: media in MediaRecord,
        on: post_media.media_id == media.id,
        where: post_media.project_id == ^project_id,
        where: like(media.mime_type, "image/%"),
        order_by: [asc: post_media.post_id, asc: post_media.sort_order, asc: post_media.media_id],
        select: {post_media.post_id, media}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp build_tag_template_slugs(project_id) do
    Repo.all(
      from tag in Tag,
        where:
          tag.project_id == ^project_id and
            not is_nil(tag.post_template_slug) and
            tag.post_template_slug != "",
        select: {tag.name, tag.post_template_slug}
    )
    |> Map.new()
  end
end
