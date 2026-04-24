defmodule BDS.PostLinks do
  @moduledoc false

  import Ecto.Query

  alias BDS.Posts.Link
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo

  def sync_post_links(%Post{} = post) do
    links =
      post
      |> post_body()
      |> extract_links()
      |> Enum.map(&resolve_post_link(post.project_id, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(fn %{target_post_id: target_post_id, link_text: link_text} ->
        {target_post_id, link_text}
      end)

    Repo.transaction(fn ->
      Repo.delete_all(from link in Link, where: link.source_post_id == ^post.id)

      now = System.system_time(:second)

      Enum.each(links, fn %{target_post_id: target_post_id, link_text: link_text} ->
        %Link{}
        |> Link.changeset(%{
          id: Ecto.UUID.generate(),
          source_post_id: post.id,
          target_post_id: target_post_id,
          link_text: link_text,
          created_at: now
        })
        |> Repo.insert!()
      end)
    end)

    :ok
  end

  def delete_post_links(post_id) when is_binary(post_id) do
    Repo.delete_all(
      from link in Link,
        where: link.source_post_id == ^post_id or link.target_post_id == ^post_id
    )

    :ok
  end

  def list_outgoing_links(post_id) when is_binary(post_id) do
    Repo.all(from link in Link, where: link.source_post_id == ^post_id, order_by: [asc: link.created_at])
  end

  def list_incoming_links(post_id) when is_binary(post_id) do
    Repo.all(from link in Link, where: link.target_post_id == ^post_id, order_by: [asc: link.created_at])
  end

  defp post_body(%Post{content: content}) when is_binary(content), do: content

  defp post_body(%Post{project_id: project_id, file_path: file_path}) do
    if file_path in [nil, ""] do
      ""
    else
      project = Projects.get_project!(project_id)
      full_path = Path.join(Projects.project_data_dir(project), file_path)

      case File.read(full_path) do
        {:ok, contents} ->
          case String.split(contents, "\n---\n", parts: 2) do
            [_frontmatter, body] -> String.trim_trailing(body, "\n")
            _parts -> contents
          end

        {:error, _reason} ->
          ""
      end
    end
  end

  defp extract_links(body) when is_binary(body) do
    markdown_links =
      Regex.scan(~r/\[([^\]]+)\]\(([^)]+)\)/, body)
      |> Enum.map(fn [_full, link_text, href] -> %{link_text: normalize_link_text(link_text), href: href} end)

    html_links =
      Regex.scan(~r/<a\s+[^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is, body)
      |> Enum.map(fn [_full, href, link_text] -> %{link_text: normalize_link_text(link_text), href: href} end)

    markdown_links ++ html_links
  end

  defp resolve_post_link(project_id, %{href: href, link_text: link_text}) do
    path =
      href
      |> to_string()
      |> String.trim()
      |> URI.parse()
      |> Map.get(:path)

    with path when is_binary(path) <- path,
         slug when is_binary(slug) <- extract_slug(path),
         %Post{id: target_post_id} <- Repo.get_by(Post, project_id: project_id, slug: slug) do
      %{target_post_id: target_post_id, link_text: link_text}
    else
      _ -> nil
    end
  end

  defp extract_slug(path) do
    segments = path |> String.split("/", trim: true)

    case segments do
      [year, month, day, slug] ->
        if numeric_year?(year) and numeric_month_or_day?(month) and numeric_month_or_day?(day),
          do: slug,
          else: nil

      [language, year, month, day, slug] ->
        if language_code?(language) and numeric_year?(year) and numeric_month_or_day?(month) and
             numeric_month_or_day?(day),
          do: slug,
          else: nil

      [slug] -> slug
      [language, slug] -> if(language_code?(language), do: slug, else: nil)
      _other -> nil
    end
  end

  defp numeric_year?(value), do: String.match?(value, ~r/^\d{4}$/)
  defp numeric_month_or_day?(value), do: String.match?(value, ~r/^\d{2}$/)
  defp language_code?(value), do: String.match?(value, ~r/^[a-z]{2}$/)

  defp normalize_link_text(value) do
    value
    |> to_string()
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
