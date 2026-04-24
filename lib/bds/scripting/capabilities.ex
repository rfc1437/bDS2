defmodule BDS.Scripting.Capabilities do
  @moduledoc false

  import Ecto.Query

  alias BDS.Metadata
  alias BDS.PostLinks
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Tags

  def for_project(project_id) when is_binary(project_id) do
    metadata = preload_metadata(project_id)
    posts = preload_posts(project_id)
    posts_by_id = Map.new(posts, &{&1["id"], &1})
    posts_by_slug = Map.new(posts, &{&1["slug"], &1})
    tags = preload_tags(project_id)

    %{
      meta: %{
        get_project_metadata: unary(fn -> metadata end)
      },
      posts: %{
        get: unary(fn post_id -> Map.get(posts_by_id, post_id) end),
        get_by_slug: unary(fn slug -> Map.get(posts_by_slug, slug) end)
      },
      tags: %{
        get_all: unary(fn -> tags end)
      }
    }
  end

  defp preload_metadata(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    sanitize(metadata)
  end

  defp preload_posts(project_id) do
    Repo.all(from(post in Post, where: post.project_id == ^project_id))
    |> Enum.map(&post_payload/1)
  end

  defp preload_tags(project_id) do
    project_id
    |> Tags.list_tags()
    |> Enum.map(&sanitize/1)
  end

  defp unary(callback) when is_function(callback, 0) do
    fn args, state ->
      _decoded_args = :luerl.decode_list(args, state)
      :luerl.encode_list([callback.()], state)
    end
  end

  defp unary(callback) when is_function(callback, 1) do
    fn args, state ->
      decoded_args = :luerl.decode_list(args, state)

      value =
        case decoded_args do
          [first | _rest] -> callback.(sanitize(first))
          [] -> callback.(nil)
        end

      :luerl.encode_list([value], state)
    end
  end

  defp post_payload(%Post{} = post) do
    post
    |> sanitize()
    |> Map.put("backlinks", linked_posts(post.id, :incoming))
    |> Map.put("links_to", linked_posts(post.id, :outgoing))
  end

  defp linked_posts(post_id, :incoming) do
    PostLinks.list_incoming_links(post_id)
    |> Enum.map(&load_linked_post(&1.source_post_id))
    |> Enum.reject(&is_nil/1)
  end

  defp linked_posts(post_id, :outgoing) do
    PostLinks.list_outgoing_links(post_id)
    |> Enum.map(&load_linked_post(&1.target_post_id))
    |> Enum.reject(&is_nil/1)
  end

  defp load_linked_post(post_id) do
    case Repo.get(Post, post_id) do
      %Post{} = post -> %{"id" => post.id, "title" => post.title, "slug" => post.slug}
      nil -> nil
    end
  end

  defp sanitize(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__, :post, :project, :media])
    |> sanitize()
  end

  defp sanitize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), sanitize(value)} end)
  end

  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value), do: value
end
