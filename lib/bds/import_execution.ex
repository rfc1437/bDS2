defmodule BDS.ImportExecution do
  @moduledoc false

  alias BDS.Media
  alias BDS.Metadata
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.MapUtils
  alias BDS.Tags

  def execute_import(project_id, report, opts \\ [])
      when is_binary(project_id) and is_map(report) do
    normalized_report = normalize_report(report)
    default_author = Keyword.get(opts, :default_author) || project_default_author(project_id)
    uploads_folder_path = Keyword.get(opts, :uploads_folder_path)
    on_progress = Keyword.get(opts, :on_progress, fn _phase, _current, _total, _detail -> :ok end)

    category_items = List.wrap(get_in(normalized_report, [:items, :categories]))
    tag_items = List.wrap(get_in(normalized_report, [:items, :tags]))

    category_mapping = build_taxonomy_mapping(category_items)
    tag_mapping = build_taxonomy_mapping(tag_items)

    post_items =
      normalized_report
      |> import_items(:posts)
      |> Enum.filter(&(Map.get(&1, :post_type, "post") == "post"))

    page_items = import_items(normalized_report, :pages)
    media_items = import_items(normalized_report, :media)
    taxonomy_total = length(category_items) + length(tag_items)

    result = %{
      success: true,
      tags: %{created: 0, skipped: 0},
      posts: %{imported: 0, skipped: 0, errors: 0},
      media: %{imported: 0, skipped: 0, errors: 0},
      pages: %{imported: 0, skipped: 0, errors: 0},
      wp_id_to_post_id: %{},
      errors: []
    }

    started_at = System.monotonic_time(:millisecond)

    notify_progress(on_progress, "tags", 0, taxonomy_total, "creating_tags", started_at)

    result =
      execute_taxonomies(category_items, tag_items, project_id, result, on_progress, started_at)

    notify_progress(on_progress, "posts", 0, length(post_items), "importing_posts", started_at)

    result =
      execute_posts(
        post_items,
        project_id,
        default_author,
        tag_mapping,
        category_mapping,
        result,
        on_progress,
        :posts,
        started_at
      )

    notify_progress(on_progress, "media", 0, length(media_items), "importing_media", started_at)

    result =
      execute_media(
        media_items,
        project_id,
        default_author,
        result,
        on_progress,
        uploads_folder_path,
        started_at
      )

    notify_progress(on_progress, "pages", 0, length(page_items), "importing_pages", started_at)

    result =
      execute_posts(
        page_items,
        project_id,
        default_author,
        tag_mapping,
        category_mapping,
        result,
        on_progress,
        :pages,
        started_at
      )

    notify_progress(on_progress, "complete", 1, 1, "import_complete", started_at)
    {:ok, result}
  rescue
    error -> {:error, %{message: Exception.message(error)}}
  end

  defp execute_taxonomies(category_items, tag_items, project_id, result, on_progress, started_at) do
    items = category_items ++ tag_items
    total = length(items)

    items
    |> Enum.with_index(1)
    |> Enum.reduce(result, fn {item, index}, acc ->
      cond do
        Map.get(item, :exists_in_project) || not is_nil(Map.get(item, :mapped_to)) ->
          notify_progress(
            on_progress,
            "tags",
            index,
            total,
            "skipped_tag:#{item.name}",
            started_at
          )

          put_in(acc, [:tags, :skipped], acc.tags.skipped + 1)

        true ->
          case Tags.create_tag(%{project_id: project_id, name: item.name}) do
            {:ok, _tag} ->
              notify_progress(
                on_progress,
                "tags",
                index,
                total,
                "created_tag:#{item.name}",
                started_at
              )

              put_in(acc, [:tags, :created], acc.tags.created + 1)

            {:error, _reason} ->
              notify_progress(
                on_progress,
                "tags",
                index,
                total,
                "skipped_tag:#{item.name}",
                started_at
              )

              put_in(acc, [:tags, :skipped], acc.tags.skipped + 1)
          end
      end
    end)
  end

  defp execute_posts(
         items,
         project_id,
         default_author,
         tag_mapping,
         category_mapping,
         result,
         on_progress,
         bucket,
         started_at
       ) do
    total = length(items)
    phase = Atom.to_string(bucket)

    Enum.with_index(items, 1)
    |> Enum.reduce(result, fn {item, index}, acc ->
      notify_progress(on_progress, phase, index, total, "processing:#{item.title}", started_at)

      execute_post_item(
        project_id,
        maybe_apply_page_category(item, bucket),
        acc,
        bucket,
        default_author,
        tag_mapping,
        category_mapping
      )
    end)
  end

  defp execute_media(
         items,
         project_id,
         default_author,
         result,
         on_progress,
         uploads_folder_path,
         started_at
       ) do
    total = length(items)

    items
    |> Enum.with_index(1)
    |> Enum.reduce(result, fn {item, index}, acc ->
      notify_progress(
        on_progress,
        "media",
        index,
        total,
        "processing:#{item.filename}",
        started_at
      )

      cond do
        item.status == "missing" ->
          put_in(acc, [:media, :skipped], acc.media.skipped + 1)

        item.status in ["update", "content-duplicate", "duplicate"] ->
          put_in(acc, [:media, :skipped], acc.media.skipped + 1)

        item.status == "conflict" and resolve_conflict(item) == "ignore" ->
          put_in(acc, [:media, :skipped], acc.media.skipped + 1)

        true ->
          case import_media_item(project_id, item, default_author, uploads_folder_path, acc) do
            {:ok, _media} ->
              put_in(acc, [:media, :imported], acc.media.imported + 1)

            {:error, reason} ->
              acc
              |> put_in([:media, :errors], acc.media.errors + 1)
              |> Map.update!(:errors, &(&1 ++ [inspect(reason)]))
              |> Map.put(:success, false)
          end
      end
    end)
  end

  defp execute_post_item(
         project_id,
         item,
         result,
         bucket,
         default_author,
         tag_mapping,
         category_mapping
       ) do
    cond do
      item.status in ["update", "content-duplicate", "duplicate"] ->
        put_in(result, [bucket, :skipped], get_in(result, [bucket, :skipped]) + 1)

      item.status == "conflict" and resolve_conflict(item) == "ignore" ->
        put_in(result, [bucket, :skipped], get_in(result, [bucket, :skipped]) + 1)

      item.status == "conflict" and resolve_conflict(item) == "overwrite" ->
        case overwrite_post_item(item, default_author, tag_mapping, category_mapping) do
          {:ok, post} ->
            result
            |> put_in([bucket, :imported], get_in(result, [bucket, :imported]) + 1)
            |> track_wp_id(item, post)

          {:error, reason} ->
            result
            |> put_in([bucket, :errors], get_in(result, [bucket, :errors]) + 1)
            |> Map.update!(:errors, &(&1 ++ [inspect(reason)]))
            |> Map.put(:success, false)
        end

      true ->
        case create_post_item(project_id, item, default_author, tag_mapping, category_mapping) do
          {:ok, post} ->
            result
            |> put_in([bucket, :imported], get_in(result, [bucket, :imported]) + 1)
            |> track_wp_id(item, post)

          {:error, reason} ->
            result
            |> put_in([bucket, :errors], get_in(result, [bucket, :errors]) + 1)
            |> Map.update!(:errors, &(&1 ++ [inspect(reason)]))
            |> Map.put(:success, false)
        end
    end
  end

  defp create_post_item(project_id, item, default_author, tag_mapping, category_mapping) do
    attrs = post_create_attrs(project_id, item, default_author, tag_mapping, category_mapping)

    with {:ok, post} <- Posts.create_post(attrs),
         :ok <- prepare_created_post(post.id, item, tag_mapping, category_mapping),
         {:ok, published_post} <- maybe_publish(post.id, item) do
      {:ok, published_post}
    end
  end

  defp overwrite_post_item(item, default_author, tag_mapping, category_mapping) do
    case Repo.get(Post, item.existing_id) do
      nil ->
        {:error, :not_found}

      %Post{} = post ->
        Posts.update_post(post.id, %{
          title: item.title,
          excerpt: item.excerpt,
          content: item.content_markdown,
          author: item.author || default_author,
          tags: resolve_taxonomy(item.tags, tag_mapping),
          categories: resolve_taxonomy(item.categories, category_mapping),
          checksum: item.content_checksum
        })
    end
  end

  defp import_media_item(project_id, item, default_author, uploads_folder_path, result) do
    source_path = item.source_file || uploads_source_path(item.relative_path, uploads_folder_path)

    checksum =
      if(source_path != nil and File.exists?(source_path),
        do: md5(File.read!(source_path)),
        else: nil
      )

    linked_post_ids = parent_post_ids(item, result)

    if source_path && File.exists?(source_path) do
      case {item.status, resolve_conflict(item)} do
        {"conflict", "overwrite"} when item.existing_id != nil ->
          with {:ok, _replaced} <- Media.replace_media_file(item.existing_id, source_path),
               {:ok, _updated_media} <-
                 Media.update_media(item.existing_id, %{
                   title: item.title,
                   alt: item.description,
                   author: default_author
                 }) do
            link_media(linked_post_ids, item.existing_id)
            {:ok, Repo.get!(Media.Media, item.existing_id)}
          end

        _ ->
          attrs = %{
            project_id: project_id,
            source_path: source_path,
            title: item.title,
            alt: item.description,
            author: default_author,
            checksum: checksum
          }

          attrs =
            if linked_post_ids == [],
              do: attrs,
              else: Map.put(attrs, :linked_post_ids, linked_post_ids)

          case Media.import_media(attrs) do
            {:ok, %{id: media_id} = media} ->
              link_media(linked_post_ids, media_id)
              {:ok, media}

            other ->
              other
          end
      end
    else
      {:error, :missing_source_file}
    end
  end

  defp link_media([], _media_id), do: :ok

  defp link_media(post_ids, media_id) when is_list(post_ids) do
    Enum.each(post_ids, fn post_id ->
      try do
        Media.link_media_to_post(media_id, post_id)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  defp parent_post_ids(item, result) do
    case Map.get(item, :parent_wp_id) do
      nil ->
        []

      0 ->
        []

      wp_id ->
        case Map.get(result.wp_id_to_post_id, wp_id) do
          nil -> []
          post_id -> [post_id]
        end
    end
  end

  defp track_wp_id(result, %{wp_id: wp_id}, %{id: post_id})
       when is_integer(wp_id) and not is_nil(post_id) do
    update_in(result, [:wp_id_to_post_id], &Map.put(&1, wp_id, post_id))
  end

  defp track_wp_id(result, _item, _post), do: result

  defp maybe_publish(post_id, item) do
    case item.wp_status do
      "publish" -> Posts.publish_post(post_id)
      _other -> {:ok, Repo.get!(Post, post_id)}
    end
  end

  defp prepare_created_post(post_id, item, tag_mapping, category_mapping) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{} = post ->
        desired_slug = desired_slug(post, item)
        created_at = parse_timestamp(item.created_at) || post.created_at
        updated_at = parse_timestamp(item.updated_at) || created_at
        published_at = parse_timestamp(item.published_at) || created_at

        post
        |> Post.changeset(%{
          slug: desired_slug,
          title: item.title,
          excerpt: item.excerpt,
          content: item.content_markdown,
          author: item.author,
          tags: resolve_taxonomy(item.tags, tag_mapping),
          categories: resolve_taxonomy(item.categories, category_mapping),
          checksum: item.content_checksum,
          created_at: created_at,
          updated_at: updated_at,
          published_at: if(item.wp_status == "publish", do: published_at, else: nil)
        })
        |> Repo.update()
        |> case do
          {:ok, _updated} -> :ok
          error -> error
        end
    end
  end

  defp desired_slug(post, item) do
    if item.status == "conflict" and resolve_conflict(item) == "import" do
      post.slug
    else
      item.slug || post.slug
    end
  end

  defp post_create_attrs(project_id, item, default_author, tag_mapping, category_mapping) do
    %{
      project_id: project_id,
      title: item.title,
      excerpt: item.excerpt,
      content: item.content_markdown,
      author: item.author || default_author,
      tags: resolve_taxonomy(item.tags, tag_mapping),
      categories: resolve_taxonomy(item.categories, category_mapping),
      checksum: item.content_checksum
    }
  end

  defp maybe_apply_page_category(item, :pages) do
    categories =
      (Map.get(item, :categories) || []) |> Enum.uniq() |> Enum.concat(["page"]) |> Enum.uniq()

    %{item | categories: categories}
  end

  defp maybe_apply_page_category(item, _bucket), do: item

  defp build_taxonomy_mapping(items) do
    Enum.reduce(items, %{}, fn item, acc ->
      key = item.name |> to_string() |> String.downcase()

      resolved =
        cond do
          present_string?(Map.get(item, :mapped_to)) -> String.downcase(item.mapped_to)
          true -> key
        end

      Map.put(acc, key, %{
        resolved: resolved,
        needs_creation:
          not item.exists_in_project and not present_string?(Map.get(item, :mapped_to))
      })
    end)
  end

  defp resolve_taxonomy(items, mapping) when is_list(items) do
    items
    |> Enum.map(fn item ->
      key = item |> to_string() |> String.downcase()

      case Map.get(mapping, key) do
        %{resolved: resolved} -> resolved
        _ -> key
      end
    end)
    |> Enum.uniq()
  end

  defp resolve_taxonomy(_items, _mapping), do: []

  defp resolve_conflict(item) do
    raw = Map.get(item, :resolution)
    normalize_resolution(raw)
  end

  defp normalize_resolution("ignore"), do: "ignore"
  defp normalize_resolution("skip"), do: "ignore"
  defp normalize_resolution("overwrite"), do: "overwrite"
  defp normalize_resolution("merge"), do: "overwrite"
  defp normalize_resolution("import"), do: "import"
  defp normalize_resolution(_other), do: "ignore"

  defp import_items(report, bucket) do
    items = get_in(report, [:items, bucket]) || []
    details = get_in(report, [:details, bucket]) || []

    if details == [] do
      Enum.map(items, &normalize_item/1)
    else
      detail_index =
        details
        |> Enum.map(&normalize_item/1)
        |> Map.new(fn item -> {item_identity(item), item} end)

      Enum.map(items, fn item ->
        normalized_item = normalize_item(item)
        identity = item_identity(normalized_item)
        detail_item = Map.get(detail_index, identity, normalized_item)

        if Map.has_key?(normalized_item, :resolution) do
          %{detail_item | resolution: normalized_item.resolution}
        else
          detail_item
        end
      end)
    end
  end

  defp item_identity(%{item_type: "media", filename: filename}), do: {:media, filename}
  defp item_identity(%{item_type: item_type, slug: slug}), do: {item_type, slug}

  defp normalize_report(report), do: MapUtils.safe_atomize_keys(report)

  defp normalize_item(item) do
    normalize_report(item)
  end

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(value) when is_integer(value), do: value

  defp parse_timestamp(value) when is_binary(value) do
    value
    |> String.replace(" ", "T")
    |> NaiveDateTime.from_iso8601()
    |> case do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC") |> DateTime.to_unix(:millisecond)
      _other -> nil
    end
  end

  defp parse_timestamp(_value), do: nil

  defp uploads_source_path(relative_path, uploads_folder_path)

  defp uploads_source_path(relative_path, uploads_folder_path)
       when is_binary(relative_path) and is_binary(uploads_folder_path) and
              uploads_folder_path != "" do
    Path.join(uploads_folder_path, relative_path)
  end

  defp uploads_source_path(_relative_path, _uploads_folder_path), do: nil

  defp notify_progress(callback, phase, current, total, detail, started_at)
       when is_function(callback, 4) do
    eta = compute_eta(current, total, started_at)

    try do
      callback.(phase, current, total, %{detail: detail, eta: eta})
    rescue
      _error ->
        try do
          callback.(phase, current, total, detail)
        rescue
          _error -> :ok
        end
    end

    :ok
  end

  defp compute_eta(current, total, started_at)
       when is_integer(current) and is_integer(total) and current > 0 and total > 0 and
              current <= total do
    elapsed = System.monotonic_time(:millisecond) - started_at
    if current >= total, do: 0, else: trunc(elapsed / current * (total - current))
  end

  defp compute_eta(_current, _total, _started_at), do: nil

  defp md5(binary) do
    :md5
    |> :crypto.hash(binary)
    |> Base.encode16(case: :lower)
  end

  defp present_string?(value) when is_binary(value) and value != "", do: true
  defp present_string?(_value), do: false

  defp project_default_author(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    metadata.default_author
  end
end
