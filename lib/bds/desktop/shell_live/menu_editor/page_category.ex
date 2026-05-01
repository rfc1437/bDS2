defmodule BDS.Desktop.ShellLive.MenuEditor.PageCategory do
  @moduledoc false

  import Ecto.Query

  alias BDS.{Metadata, Repo}
  alias BDS.Posts.Post

  @spec page_posts(term()) :: term()
  def page_posts(nil), do: []

  def page_posts(project_id) do
    Repo.all(
      from post in Post,
        where: post.project_id == ^project_id,
        order_by: [asc: post.title, asc: post.slug]
    )
    |> Enum.filter(&("page" in (&1.categories || [])))
  end

  @spec page_post(term(), term()) :: term()
  def page_post(nil, _post_id), do: nil

  def page_post(project_id, post_id) do
    Enum.find(page_posts(project_id), &(&1.id == post_id))
  end

  @spec filter_page_posts(term(), term()) :: term()
  def filter_page_posts(posts, query) do
    normalized = query |> to_string() |> String.trim() |> String.downcase()

    Enum.filter(posts, fn post ->
      normalized == "" or
        String.contains?(String.downcase(post.title || ""), normalized) or
        String.contains?(String.downcase(post.slug || ""), normalized)
    end)
  end

  @spec category_options(term()) :: term()
  def category_options(nil), do: []

  def category_options(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    Enum.map(metadata.categories || [], fn name ->
      title = get_in(metadata.category_settings || %{}, [name, "title"])
      %{name: name, title: blank_to_nil(title) || name}
    end)
  end

  @spec filter_categories(term(), term()) :: term()
  def filter_categories(categories, query) do
    normalized = query |> to_string() |> String.trim() |> String.downcase()

    Enum.filter(categories, fn category ->
      normalized == "" or
        String.contains?(String.downcase(category.name), normalized) or
        String.contains?(String.downcase(category.title), normalized)
    end)
  end

  @spec blank_to_nil(term()) :: term()
  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) do
    trimmed = String.trim(to_string(value))
    if trimmed == "", do: nil, else: trimmed
  end
end
