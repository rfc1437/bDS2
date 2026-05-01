defmodule BDS.MCP.Resources do
  @moduledoc false

  import Ecto.Query

  alias BDS.MCP.ProposalStore
  alias BDS.MCP.Queries
  alias BDS.MCP.Util
  alias BDS.Media.Media, as: MediaAsset
  alias BDS.Metadata
  alias BDS.Posts.PostMedia
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Search
  alias BDS.Tags

  @typedoc "Resource descriptor returned by `list/0`."
  @type descriptor :: %{name: String.t(), uri: String.t()}

  @typedoc "Resource template descriptor returned by `templates/0`."
  @type template_descriptor :: %{name: String.t(), uriTemplate: String.t()}

  @spec list() :: [descriptor()]
  def list do
    [
      %{name: "posts", uri: "bds://posts"},
      %{name: "media", uri: "bds://media"},
      %{name: "tags", uri: "bds://tags"},
      %{name: "categories", uri: "bds://categories"},
      %{name: "stats", uri: "bds://stats"}
    ]
  end

  @spec templates() :: [template_descriptor()]
  def templates do
    [
      %{name: "posts", uriTemplate: "bds://posts{?cursor}"},
      %{name: "media", uriTemplate: "bds://media{?cursor}"},
      %{name: "post media", uriTemplate: "bds://posts/{id}/media"},
      %{name: "media image", uriTemplate: "bds://media/{id}/image"}
    ]
  end

  @spec read(String.t()) :: {:ok, term()} | {:error, term()}
  def read(uri) when is_binary(uri) do
    ProposalStore.ensure_started()

    case URI.parse(uri) do
      %URI{scheme: "bds", host: "posts", path: nil, query: query} -> posts_resource(query)
      %URI{scheme: "bds", host: "media", path: nil, query: query} -> media_resource(query)
      %URI{scheme: "bds", host: "tags", path: nil} -> {:ok, tags_resource()}
      %URI{scheme: "bds", host: "categories", path: nil} -> {:ok, categories_resource()}
      %URI{scheme: "bds", host: "stats", path: nil} -> {:ok, stats_resource()}
      %URI{scheme: "bds", host: "posts", path: path} -> read_posts_path(path)
      %URI{scheme: "bds", host: "media", path: path} -> read_media_path(path)
      _other -> {:error, :not_found}
    end
  end

  defp posts_resource(query) do
    with {:ok, offset} <- cursor_offset(query) do
      {:ok, posts_page(offset)}
    end
  end

  defp posts_page(offset) do
    project = Queries.active_project!()
    page_size = Queries.page_size()
    {:ok, result} = Search.search_posts(project.id, "", %{offset: offset, limit: page_size})

    %{
      "items" => Enum.map(result.posts, &Queries.post_summary/1),
      "total" => result.total,
      "offset" => result.offset,
      "limit" => result.limit
    }
    |> maybe_put_next_cursor(result)
  end

  defp media_resource(query) do
    with {:ok, offset} <- cursor_offset(query) do
      {:ok, media_page(offset)}
    end
  end

  defp media_page(offset) do
    project = Queries.active_project!()
    page_size = Queries.page_size()
    {:ok, result} = Search.search_media(project.id, "", %{offset: offset, limit: page_size})

    %{
      "items" => Enum.map(result.media, &Util.sanitize/1),
      "total" => result.total,
      "offset" => result.offset,
      "limit" => result.limit
    }
    |> maybe_put_next_cursor(result)
  end

  defp cursor_offset(nil), do: {:ok, 0}

  defp cursor_offset(query) do
    case URI.decode_query(query) do
      %{"cursor" => cursor} when cursor != "" -> decode_cursor(cursor)
      %{"cursor" => ""} -> {:error, :invalid_cursor}
      _params -> {:ok, 0}
    end
  end

  defp decode_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"offset" => offset}} when is_integer(offset) and offset >= 0 <-
           Jason.decode(decoded) do
      {:ok, offset}
    else
      _other -> {:error, :invalid_cursor}
    end
  end

  defp maybe_put_next_cursor(resource, result) do
    next_offset = result.offset + result.limit

    if next_offset < result.total do
      Map.put(resource, "nextCursor", encode_cursor(next_offset))
    else
      resource
    end
  end

  defp encode_cursor(offset) do
    %{"offset" => offset}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp tags_resource do
    project = Queries.active_project!()
    tags = Tags.list_tags(project.id)

    %{
      "items" =>
        Enum.map(tags, fn tag ->
          %{
            "id" => tag.id,
            "name" => tag.name,
            "color" => tag.color,
            "post_count" => Queries.tag_post_count(project.id, tag.name)
          }
        end)
    }
  end

  defp categories_resource do
    project = Queries.active_project!()
    {:ok, metadata} = Metadata.get_project_metadata(project.id)

    %{
      "items" =>
        Enum.map(metadata.categories, fn category ->
          %{"name" => category, "post_count" => Queries.category_post_count(project.id, category)}
        end)
    }
  end

  defp stats_resource do
    project = Queries.active_project!()
    {:ok, posts} = Search.search_posts(project.id, "", %{offset: 0, limit: 1})
    {:ok, media} = Search.search_media(project.id, "", %{offset: 0, limit: 1})
    {:ok, metadata} = Metadata.get_project_metadata(project.id)

    %{
      "posts" => posts.total,
      "media" => media.total,
      "tags" => length(Tags.list_tags(project.id)),
      "categories" => length(metadata.categories)
    }
  end

  defp read_posts_path("/" <> path) do
    case String.split(path, "/", trim: true) do
      [id] -> read_post_resource(id)
      [id, "media"] -> read_post_media_resource(id)
      _parts -> {:error, :not_found}
    end
  end

  defp read_posts_path(_path), do: {:error, :not_found}

  defp read_media_path("/" <> path) do
    case String.split(path, "/", trim: true) do
      [id] -> read_media_resource(id)
      [id, "image"] -> read_media_image_resource(id)
      _parts -> {:error, :not_found}
    end
  end

  defp read_media_path(_path), do: {:error, :not_found}

  defp read_post_resource(id) do
    case Repo.get(Post, id) do
      %Post{} = post -> {:ok, Queries.post_detail(post)}
      nil -> {:error, :not_found}
    end
  end

  defp read_media_resource(id) do
    case Repo.get(MediaAsset, id) do
      %MediaAsset{} = media -> {:ok, Util.sanitize(media)}
      nil -> {:error, :not_found}
    end
  end

  defp read_post_media_resource(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{} ->
        items =
          Repo.all(
            from media in MediaAsset,
              join: post_media in PostMedia,
              on: post_media.media_id == media.id,
              where: post_media.post_id == ^post_id,
              order_by: [asc: post_media.sort_order, asc: media.updated_at],
              select: media
          )

        {:ok, %{"items" => Enum.map(items, &Util.sanitize/1)}}
    end
  end

  defp read_media_image_resource(id) do
    case Repo.get(MediaAsset, id) do
      nil ->
        {:error, :not_found}

      %MediaAsset{} = media ->
        project = Projects.get_project!(media.project_id)
        full_path = Path.join(Projects.project_data_dir(project), media.file_path || "")

        case File.read(full_path) do
          {:ok, bytes} ->
            {:ok,
             %{
               "mimeType" => media.mime_type || "application/octet-stream",
               "blob" => Base.encode64(bytes)
             }}

          {:error, _reason} ->
            {:error, :not_found}
        end
    end
  end
end
