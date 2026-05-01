defmodule BDS.MCP.Resources do
  @moduledoc false

  alias BDS.MCP.ProposalStore
  alias BDS.MCP.Queries
  alias BDS.MCP.Util
  alias BDS.Media.Media, as: MediaAsset
  alias BDS.Metadata
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Search
  alias BDS.Tags

  @typedoc "Resource descriptor returned by `list/0`."
  @type descriptor :: %{name: String.t(), uri: String.t()}

  @spec list() :: [descriptor()]
  def list do
    [
      %{name: "posts", uri: "bds://posts"},
      %{name: "media", uri: "bds://media"},
      %{name: "tags", uri: "bds://tags"},
      %{name: "categories", uri: "bds://categories"}
    ]
  end

  @spec read(String.t()) :: {:ok, term()} | {:error, term()}
  def read(uri) when is_binary(uri) do
    ProposalStore.ensure_started()

    case URI.parse(uri) do
      %URI{scheme: "bds", host: "posts", path: nil} -> {:ok, posts_resource(0)}
      %URI{scheme: "bds", host: "media", path: nil} -> {:ok, media_resource(0)}
      %URI{scheme: "bds", host: "tags", path: nil} -> {:ok, tags_resource()}
      %URI{scheme: "bds", host: "categories", path: nil} -> {:ok, categories_resource()}
      %URI{scheme: "bds", host: "posts", path: "/" <> id} -> read_post_resource(id)
      %URI{scheme: "bds", host: "media", path: "/" <> id} -> read_media_resource(id)
      _other -> {:error, :not_found}
    end
  end

  defp posts_resource(offset) do
    project = Queries.active_project!()
    page_size = Queries.page_size()
    {:ok, result} = Search.search_posts(project.id, "", %{offset: offset, limit: page_size})

    %{
      "items" => Enum.map(result.posts, &Queries.post_summary/1),
      "total" => result.total,
      "offset" => result.offset,
      "limit" => result.limit,
      "has_more" => result.offset + result.limit < result.total
    }
  end

  defp media_resource(offset) do
    project = Queries.active_project!()
    page_size = Queries.page_size()
    {:ok, result} = Search.search_media(project.id, "", %{offset: offset, limit: page_size})

    %{
      "items" => Enum.map(result.media, &Util.sanitize/1),
      "total" => result.total,
      "offset" => result.offset,
      "limit" => result.limit,
      "has_more" => result.offset + result.limit < result.total
    }
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
end
