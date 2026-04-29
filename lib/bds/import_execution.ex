defmodule BDS.ImportExecution do
  @moduledoc false

  alias BDS.Media
  alias BDS.Metadata
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Tags

  def execute_import(project_id, report, opts \\ []) when is_binary(project_id) and is_map(report) do
    normalized_report = normalize_report(report)
    default_author = Keyword.get(opts, :default_author) || project_default_author(project_id)

    result = %{
      success: true,
      tags: %{created: 0, skipped: 0},
      posts: %{imported: 0, skipped: 0, errors: 0},
      media: %{imported: 0, skipped: 0, errors: 0},
      pages: %{imported: 0, skipped: 0, errors: 0},
      errors: []
    }

    result = execute_taxonomies(normalized_report, project_id, result)
    result = execute_posts(normalized_report, project_id, default_author, result)
    result = execute_pages(normalized_report, project_id, default_author, result)

    {:ok, execute_media(normalized_report, project_id, default_author, result)}
  rescue
    error -> {:error, %{message: Exception.message(error)}}
  end

  defp execute_taxonomies(report, project_id, result) do
    taxonomies = List.wrap(get_in(report, [:items, :categories])) ++ List.wrap(get_in(report, [:items, :tags]))

    Enum.reduce(taxonomies, result, fn item, acc ->
      if item.exists_in_project || item.mapped_to do
        put_in(acc, [:tags, :skipped], acc.tags.skipped + 1)
      else
        case Tags.create_tag(%{project_id: project_id, name: item.name}) do
          {:ok, _tag} -> put_in(acc, [:tags, :created], acc.tags.created + 1)
          {:error, _reason} -> put_in(acc, [:tags, :skipped], acc.tags.skipped + 1)
        end
      end
    end)
  end

  defp execute_posts(report, project_id, default_author, result) do
    items = import_items(report, :posts)

    Enum.reduce(items, result, fn item, acc ->
      execute_post_item(project_id, item, acc, :posts, default_author)
    end)
  end

  defp execute_pages(report, project_id, default_author, result) do
    items = import_items(report, :pages)

    Enum.reduce(items, result, fn item, acc ->
      execute_post_item(project_id, ensure_page_category(item), acc, :pages, default_author)
    end)
  end

  defp execute_media(report, project_id, default_author, result) do
    import_items(report, :media)
    |> Enum.reduce(result, fn item, acc ->
      cond do
        item.status in ["update", "duplicate", "missing"] ->
          put_in(acc, [:media, :skipped], acc.media.skipped + 1)

        item.status == "conflict" and item.resolution != "import" and item.resolution != "merge" ->
          put_in(acc, [:media, :skipped], acc.media.skipped + 1)

        true ->
          case import_media_item(project_id, item, default_author) do
            {:ok, _media} -> put_in(acc, [:media, :imported], acc.media.imported + 1)
            {:error, reason} ->
              acc
              |> put_in([:media, :errors], acc.media.errors + 1)
              |> Map.update!(:errors, &(&1 ++ [inspect(reason)]))
              |> Map.put(:success, false)
          end
      end
    end)
  end

  defp execute_post_item(project_id, item, result, bucket, default_author) do
    cond do
      item.status in ["update", "duplicate"] ->
        put_in(result, [bucket, :skipped], get_in(result, [bucket, :skipped]) + 1)

      item.status == "conflict" and item.resolution not in ["import", "merge"] ->
        put_in(result, [bucket, :skipped], get_in(result, [bucket, :skipped]) + 1)

      item.status == "conflict" and item.resolution == "merge" ->
        case merge_post_item(item, default_author) do
          {:ok, _post} -> put_in(result, [bucket, :imported], get_in(result, [bucket, :imported]) + 1)
          {:error, reason} ->
            result
            |> put_in([bucket, :errors], get_in(result, [bucket, :errors]) + 1)
            |> Map.update!(:errors, &(&1 ++ [inspect(reason)]))
            |> Map.put(:success, false)
        end

      true ->
        case create_post_item(project_id, item, default_author) do
          {:ok, _post} -> put_in(result, [bucket, :imported], get_in(result, [bucket, :imported]) + 1)
          {:error, reason} ->
            result
            |> put_in([bucket, :errors], get_in(result, [bucket, :errors]) + 1)
            |> Map.update!(:errors, &(&1 ++ [inspect(reason)]))
            |> Map.put(:success, false)
        end
    end
  end

  defp create_post_item(project_id, item, default_author) do
    attrs = post_create_attrs(project_id, item, default_author)

    with {:ok, post} <- Posts.create_post(attrs),
         :ok <- prepare_created_post(post.id, item),
         {:ok, published_post} <- maybe_publish(post.id, item) do
      {:ok, published_post}
    end
  end

  defp merge_post_item(item, default_author) do
    case Repo.get(Post, item.existing_id) do
      nil -> {:error, :not_found}

      %Post{} = post ->
        Posts.update_post(post.id, %{
          title: item.title,
          excerpt: item.excerpt,
          content: item.content_markdown,
          author: item.author || default_author,
          tags: item.tags,
          categories: item.categories,
          checksum: item.content_checksum
        })
    end
  end

  defp import_media_item(project_id, item, default_author) do
    source_path = item.source_file || Path.join("", item.relative_path)
    checksum = if(source_path != nil and File.exists?(source_path), do: md5(File.read!(source_path)), else: nil)

    if source_path && File.exists?(source_path) do
      case item.status do
        "conflict" when item.resolution == "merge" and item.existing_id ->
          with {:ok, _updated_media} <- Media.update_media(item.existing_id, %{title: item.title, alt: item.description, author: default_author}) do
            {:ok, Repo.get!(Media.Media, item.existing_id)}
          end

        _other ->
          Media.import_media(%{
            project_id: project_id,
            source_path: source_path,
            title: item.title,
            alt: item.description,
            author: default_author,
            checksum: checksum
          })
      end
    else
      {:error, :missing_source_file}
    end
  end

  defp maybe_publish(post_id, item) do
    case item.wp_status do
      "publish" -> Posts.publish_post(post_id)
      _other -> {:ok, Repo.get!(Post, post_id)}
    end
  end

  defp prepare_created_post(post_id, item) do
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
          tags: item.tags,
          categories: item.categories,
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
    if item.status == "conflict" and item.resolution == "import" do
      post.slug
    else
      item.slug || post.slug
    end
  end

  defp post_create_attrs(project_id, item, default_author) do
    %{
      project_id: project_id,
      title: item.title,
      excerpt: item.excerpt,
      content: item.content_markdown,
      author: item.author || default_author,
      tags: item.tags,
      categories: item.categories,
      checksum: item.content_checksum
    }
  end

  defp ensure_page_category(item) do
    categories = (item.categories || []) |> Enum.uniq() |> Enum.concat(["page"]) |> Enum.uniq()
    %{item | categories: categories}
  end

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

  defp normalize_report(report) when is_map(report) do
    report
    |> Enum.map(fn {key, value} ->
      normalized_key = if(is_binary(key), do: String.to_atom(key), else: key)
      {normalized_key, normalize_report(value)}
    end)
    |> Map.new()
  end

  defp normalize_report(report) when is_list(report), do: Enum.map(report, &normalize_report/1)
  defp normalize_report(report), do: report

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

  defp md5(binary) do
    :md5
    |> :crypto.hash(binary)
    |> Base.encode16(case: :lower)
  end

  defp project_default_author(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    Map.get(metadata, :default_author)
  end
end
