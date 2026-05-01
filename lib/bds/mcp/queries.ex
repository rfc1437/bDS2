defmodule BDS.MCP.Queries do
  @moduledoc false

  import Ecto.Query

  alias BDS.MCP.Util
  alias BDS.PostLinks
  alias BDS.Posts.Post
  alias BDS.Posts.Translation, as: PostTranslation
  alias BDS.Projects
  alias BDS.Repo

  @page_size 50

  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @spec active_project!() :: Projects.Project.t()
  def active_project! do
    case Enum.find(Projects.list_projects(), & &1.is_active) do
      nil -> raise "no active project"
      project -> project
    end
  end

  @spec post_summary(Post.t()) :: map()
  def post_summary(%Post{} = post) do
    %{
      "id" => post.id,
      "title" => post.title,
      "slug" => post.slug,
      "status" => Atom.to_string(post.status),
      "tags" => post.tags || [],
      "categories" => post.categories || [],
      "created_at" => post.created_at,
      "backlinks" => linked_posts(post.id, :incoming),
      "links_to" => linked_posts(post.id, :outgoing)
    }
  end

  @spec post_detail(Post.t()) :: map()
  def post_detail(%Post{} = post) do
    post
    |> Util.sanitize()
    |> Map.put("content", post_body(post))
    |> Map.put("backlinks", linked_posts(post.id, :incoming))
    |> Map.put("links_to", linked_posts(post.id, :outgoing))
    |> Map.put("available_languages", available_languages(post.id, post.language))
  end

  @spec translated_post_detail(Post.t(), String.t()) :: map()
  def translated_post_detail(%Post{} = post, language) do
    normalized_language = Util.normalize_term(language)

    case Repo.get_by(PostTranslation, translation_for: post.id, language: normalized_language) do
      nil ->
        post_detail(post)

      %PostTranslation{} = translation ->
        post_detail(post)
        |> Map.put("title", translation.title)
        |> Map.put("excerpt", translation.excerpt)
        |> Map.put("content", translation_body(translation))
        |> Map.put("language", translation.language)
        |> Map.put("canonical_language", post.language)
    end
  end

  @spec search_filters(map()) :: map()
  def search_filters(params) do
    %{}
    |> Util.maybe_put(:category, Util.map_get(params, :category))
    |> Util.maybe_put(:tags, Util.map_get(params, :tags))
    |> Util.maybe_put(:language, Util.map_get(params, :language))
    |> Util.maybe_put(:missing_translation_language, Util.map_get(params, :missingTranslationLanguage))
    |> Util.maybe_put(:year, Util.map_get(params, :year))
    |> Util.maybe_put(:month, Util.map_get(params, :month))
    |> Util.maybe_put(:status, parse_status(Util.map_get(params, :status)))
    |> Map.put(:offset, Util.map_get(params, :offset, 0))
    |> Map.put(:limit, Util.map_get(params, :limit, @page_size))
  end

  @spec parse_status(term()) :: atom() | nil
  def parse_status(nil), do: nil
  def parse_status(status) when is_atom(status), do: status
  def parse_status(status) when is_binary(status), do: String.to_existing_atom(status)

  @spec group_rows(Post.t(), [String.t()]) :: [map()]
  def group_rows(_post, []), do: [%{}]

  def group_rows(post, [dimension | rest]) do
    values = group_values(post, dimension)

    for value <- values,
        tail <- group_rows(post, rest) do
      Map.put(tail, dimension, value)
    end
  end

  defp group_values(post, "year") do
    [BDS.Persistence.from_unix_ms!(post.created_at).year]
  end

  defp group_values(post, "month") do
    [BDS.Persistence.from_unix_ms!(post.created_at).month]
  end

  defp group_values(post, "tag") do
    if Enum.empty?(post.tags || []), do: [nil], else: post.tags
  end

  defp group_values(post, "category") do
    if Enum.empty?(post.categories || []), do: [nil], else: post.categories
  end

  defp group_values(post, "status"), do: [Atom.to_string(post.status)]

  @spec available_languages(String.t(), String.t() | nil) :: [String.t()]
  def available_languages(post_id, canonical_language) do
    languages =
      Repo.all(
        from translation in PostTranslation,
          where: translation.translation_for == ^post_id,
          select: translation.language
      )

    ([canonical_language] ++ languages)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  @spec linked_posts(String.t(), :incoming | :outgoing) :: [map()]
  def linked_posts(post_id, :incoming) do
    PostLinks.list_incoming_links(post_id)
    |> Enum.map(&load_linked_post(&1.source_post_id))
    |> Enum.reject(&is_nil/1)
  end

  def linked_posts(post_id, :outgoing) do
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

  @spec post_body(Post.t()) :: String.t()
  def post_body(%Post{content: content}) when is_binary(content), do: content

  def post_body(%Post{} = post) do
    project = Projects.get_project!(post.project_id)
    full_path = Path.join(Projects.project_data_dir(project), post.file_path || "")

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

  @spec translation_body(PostTranslation.t()) :: String.t()
  def translation_body(%PostTranslation{content: content}) when is_binary(content), do: content

  def translation_body(%PostTranslation{} = translation) do
    project = Projects.get_project!(translation.project_id)
    full_path = Path.join(Projects.project_data_dir(project), translation.file_path || "")

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

  @spec tag_post_count(String.t(), String.t()) :: non_neg_integer()
  def tag_post_count(project_id, tag_name) do
    Repo.all(from post in Post, where: post.project_id == ^project_id)
    |> Enum.count(&(tag_name in (&1.tags || [])))
  end

  @spec category_post_count(String.t(), String.t()) :: non_neg_integer()
  def category_post_count(project_id, category) do
    Repo.all(from post in Post, where: post.project_id == ^project_id)
    |> Enum.count(&(category in (&1.categories || [])))
  end
end
