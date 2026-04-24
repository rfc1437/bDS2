defmodule BDS.MCP do
  @moduledoc false

  import Ecto.Query

  alias BDS.Media
  alias BDS.Media.Media, as: MediaAsset
  alias BDS.Metadata
  alias BDS.MCP.ProposalStore
  alias BDS.PostLinks
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Posts.Translation, as: PostTranslation
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Scripts
  alias BDS.Search
  alias BDS.Tags
  alias BDS.Templates

  @page_size 50
  @proposal_ttl_app_ms 30 * 60 * 1000

  def list_tools do
    [
      tool("check_term", true),
      tool("search_posts", true),
      tool("count_posts", true),
      tool("read_post_by_slug", true),
      tool("draft_post", false),
      tool("propose_script", false),
      tool("propose_template", false),
      tool("propose_media_metadata", false),
      tool("propose_post_metadata", false),
      tool("accept_proposal", false),
      tool("discard_proposal", false)
    ]
  end

  def list_resources do
    [
      %{name: "posts", uri: "bds://posts"},
      %{name: "media", uri: "bds://media"},
      %{name: "tags", uri: "bds://tags"},
      %{name: "categories", uri: "bds://categories"}
    ]
  end

  def call_tool(name, params) when is_binary(name) and is_map(params) do
    ProposalStore.ensure_started()

    case name do
      "check_term" -> {:ok, check_term(params)}
      "search_posts" -> {:ok, search_posts(params)}
      "count_posts" -> {:ok, count_posts(params)}
      "read_post_by_slug" -> read_post_by_slug(params)
      "draft_post" -> draft_post(params)
      "propose_script" -> propose_script(params)
      "propose_template" -> propose_template(params)
      "propose_media_metadata" -> propose_media_metadata(params)
      "propose_post_metadata" -> propose_post_metadata(params)
      "accept_proposal" -> accept_proposal(params)
      "discard_proposal" -> discard_proposal(params)
      _other -> {:error, :unknown_tool}
    end
  end

  def read_resource(uri) when is_binary(uri) do
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

  def validate_template(source) when is_binary(source) do
    case Liquex.parse(source) do
      {:ok, _ast} -> {:ok, %{valid: true, errors: []}}
      {:error, reason, line} -> {:ok, %{valid: false, errors: ["#{inspect(reason)} at line #{line}"]}}
    end
  end

  defp tool(name, read_only) do
    %{
      name: name,
      annotations: %{"readOnlyHint" => read_only, "destructiveHint" => false}
    }
  end

  defp active_project! do
    case Enum.find(Projects.list_projects(), & &1.is_active) do
      nil -> raise "no active project"
      project -> project
    end
  end

  defp check_term(%{"term" => term}), do: check_term(%{term: term})

  defp check_term(%{term: term}) do
    project = active_project!()
    normalized = normalize_term(term)

    posts = Repo.all(from post in Post, where: post.project_id == ^project.id)

    tag_post_count =
      Enum.count(posts, fn post ->
        Enum.any?(post.tags || [], &(normalize_term(&1) == normalized))
      end)

    category_post_count =
      Enum.count(posts, fn post ->
        Enum.any?(post.categories || [], &(normalize_term(&1) == normalized))
      end)

    %{
      "is_category" => category_post_count > 0,
      "category_post_count" => category_post_count,
      "is_tag" => tag_post_count > 0,
      "tag_post_count" => tag_post_count
    }
  end

  defp search_posts(params) do
    project = active_project!()
    filters = search_filters(params)
    query = map_get(params, :query, "")
    {:ok, result} = Search.search_posts(project.id, query, filters)

    posts = Enum.map(result.posts, &post_summary/1)

    %{
      "posts" => posts,
      "total" => result.total,
      "offset" => result.offset,
      "limit" => result.limit,
      "has_more" => result.offset + result.limit < result.total
    }
  end

  defp count_posts(params) do
    project = active_project!()
    group_by = map_get(params, :groupBy, []) |> Enum.map(&to_string/1)
    filters = search_filters(params)
    {:ok, result} = Search.search_posts(project.id, "", filters)

    groups =
      result.posts
      |> Enum.flat_map(&group_rows(&1, group_by))
      |> Enum.group_by(& &1, fn _row -> 1 end)
      |> Enum.map(fn {row, counts} -> Map.put(row, "count", length(counts)) end)
      |> Enum.sort_by(&Map.to_list/1)

    %{"groups" => groups, "total_posts" => result.total}
  end

  defp read_post_by_slug(%{"slug" => slug} = params), do: read_post_by_slug(Map.put_new(params, :slug, slug))

  defp read_post_by_slug(%{slug: slug} = params) do
    project = active_project!()

    case Repo.get_by(Post, project_id: project.id, slug: slug) do
      nil -> {:error, :not_found}
      %Post{} = post ->
        payload =
          case map_get(params, :language) do
            nil -> post_detail(post)
            "" -> post_detail(post)
            language ->
              if normalize_term(language) == normalize_term(post.language) do
                post_detail(post)
              else
                translated_post_detail(post, language)
              end
          end

        {:ok, %{"post" => payload}}
    end
  end

  defp draft_post(params) do
    project = active_project!()

    attrs = %{
      project_id: project.id,
      title: map_get(params, :title, ""),
      content: map_get(params, :content, ""),
      excerpt: map_get(params, :excerpt),
      tags: map_get(params, :tags, []),
      categories: map_get(params, :categories, []),
      author: map_get(params, :author)
    }

    with {:ok, post} <- Posts.create_post(attrs) do
      proposal =
        ProposalStore.create("draft_post", %{"post_id" => post.id}, ttl_ms: @proposal_ttl_app_ms)

      {:ok, %{"proposal_id" => proposal.id, "post" => sanitize(post)}}
    end
  end

  defp propose_script(params) do
    project = active_project!()
    content = map_get(params, :content, "")

    with validation <- script_validation(content),
         {:ok, script} <-
           Scripts.create_script(%{
             project_id: project.id,
             title: map_get(params, :title, ""),
             kind: parse_script_kind(map_get(params, :kind)),
             content: content,
             entrypoint: map_get(params, :entrypoint)
           }) do
      proposal =
        ProposalStore.create("propose_script", %{"script_id" => script.id}, ttl_ms: @proposal_ttl_app_ms)

      {:ok,
       %{
         "proposal_id" => proposal.id,
         "script" => sanitize(script),
         "preview" => %{
           "title" => script.title,
           "kind" => Atom.to_string(script.kind),
           "content_length" => String.length(content),
           "syntax_valid" => validation.valid,
           "syntax_errors" => validation.errors
         }
       }}
    end
  end

  defp propose_template(params) do
    project = active_project!()
    content = map_get(params, :content, "")
    {:ok, validation} = validate_template(content)

    with {:ok, template} <-
           Templates.create_template(%{
             project_id: project.id,
             title: map_get(params, :title, ""),
             kind: parse_template_kind(map_get(params, :kind)),
             content: content
           }) do
      proposal =
        ProposalStore.create("propose_template", %{"template_id" => template.id}, ttl_ms: @proposal_ttl_app_ms)

      {:ok,
       %{
         "proposal_id" => proposal.id,
         "template" => sanitize(template),
         "preview" => %{
           "title" => template.title,
           "kind" => Atom.to_string(template.kind),
           "content_length" => String.length(content),
           "syntax_valid" => validation.valid,
           "syntax_errors" => validation.errors
         }
       }}
    end
  end

  defp propose_media_metadata(params) do
    media_id = map_get(params, :mediaId)

    case Repo.get(MediaAsset, media_id) do
      nil -> {:error, :not_found}
      %MediaAsset{} = media ->
        changes =
          %{}
          |> maybe_put("title", map_get(params, :title))
          |> maybe_put("alt", map_get(params, :alt))
          |> maybe_put("caption", map_get(params, :caption))
          |> maybe_put("tags", map_get(params, :tags))

        proposal =
          ProposalStore.create(
            "propose_media_metadata",
            %{"media_id" => media_id, "changes" => changes},
            ttl_ms: @proposal_ttl_app_ms
          )

        {:ok, %{"proposal_id" => proposal.id, "current" => sanitize(media), "proposed" => changes}}
    end
  end

  defp propose_post_metadata(params) do
    post_id = map_get(params, :postId)

    case Repo.get(Post, post_id) do
      nil -> {:error, :not_found}
      %Post{} = post ->
        changes =
          %{}
          |> maybe_put("title", map_get(params, :title))
          |> maybe_put("excerpt", map_get(params, :excerpt))
          |> maybe_put("tags", map_get(params, :tags))
          |> maybe_put("categories", map_get(params, :categories))

        proposal =
          ProposalStore.create(
            "propose_post_metadata",
            %{"post_id" => post_id, "changes" => changes},
            ttl_ms: @proposal_ttl_app_ms
          )

        {:ok, %{"proposal_id" => proposal.id, "current" => sanitize(post), "proposed" => changes}}
    end
  end

  defp accept_proposal(params) do
    proposal_id = map_get(params, :proposalId)

    case ProposalStore.get(proposal_id) do
      nil -> {:error, :not_found}
      proposal ->
        result =
          case proposal.kind do
            "draft_post" ->
              proposal.data["post_id"] |> Posts.publish_post()

            "propose_script" ->
              proposal.data["script_id"] |> Scripts.publish_script()

            "propose_template" ->
              proposal.data["template_id"] |> Templates.publish_template()

            "propose_media_metadata" ->
              Media.update_media(proposal.data["media_id"], atomize_keys(proposal.data["changes"]))

            "propose_post_metadata" ->
              Posts.update_post(proposal.data["post_id"], atomize_keys(proposal.data["changes"]))

            _other ->
              {:error, :unsupported_proposal}
          end

        case result do
          {:ok, value} ->
            :ok = ProposalStore.remove(proposal_id)
            {:ok, %{"success" => true, "message" => "accepted", "result" => sanitize(value)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp discard_proposal(params) do
    proposal_id = map_get(params, :proposalId)

    case ProposalStore.get(proposal_id) do
      nil -> {:error, :not_found}
      proposal ->
        result =
          case proposal.kind do
            "draft_post" -> Posts.delete_post(proposal.data["post_id"])
            "propose_script" -> Scripts.delete_script(proposal.data["script_id"])
            "propose_template" -> Templates.delete_template(proposal.data["template_id"])
            _other -> {:ok, :discarded}
          end

        case result do
          {:ok, _value} ->
            :ok = ProposalStore.remove(proposal_id)
            {:ok, %{"success" => true, "message" => "discarded"}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp posts_resource(offset) do
    project = active_project!()
    {:ok, result} = Search.search_posts(project.id, "", %{offset: offset, limit: @page_size})

    %{
      "items" => Enum.map(result.posts, &post_summary/1),
      "total" => result.total,
      "offset" => result.offset,
      "limit" => result.limit,
      "has_more" => result.offset + result.limit < result.total
    }
  end

  defp media_resource(offset) do
    project = active_project!()
    {:ok, result} = Search.search_media(project.id, "", %{offset: offset, limit: @page_size})

    %{
      "items" => Enum.map(result.media, &sanitize/1),
      "total" => result.total,
      "offset" => result.offset,
      "limit" => result.limit,
      "has_more" => result.offset + result.limit < result.total
    }
  end

  defp tags_resource do
    project = active_project!()
    tags = Tags.list_tags(project.id)

    %{
      "items" =>
        Enum.map(tags, fn tag ->
          %{
            "id" => tag.id,
            "name" => tag.name,
            "color" => tag.color,
            "post_count" => tag_post_count(project.id, tag.name)
          }
        end)
    }
  end

  defp categories_resource do
    project = active_project!()
    {:ok, metadata} = Metadata.get_project_metadata(project.id)

    %{
      "items" =>
        Enum.map(metadata.categories, fn category ->
          %{"name" => category, "post_count" => category_post_count(project.id, category)}
        end)
    }
  end

  defp read_post_resource(id) do
    case Repo.get(Post, id) do
      %Post{} = post -> {:ok, post_detail(post)}
      nil -> {:error, :not_found}
    end
  end

  defp read_media_resource(id) do
    case Repo.get(MediaAsset, id) do
      %MediaAsset{} = media -> {:ok, sanitize(media)}
      nil -> {:error, :not_found}
    end
  end

  defp post_detail(%Post{} = post) do
    post
    |> sanitize()
    |> Map.put("content", post_body(post))
    |> Map.put("backlinks", linked_posts(post.id, :incoming))
    |> Map.put("links_to", linked_posts(post.id, :outgoing))
    |> Map.put("available_languages", available_languages(post.id, post.language))
  end

  defp translated_post_detail(%Post{} = post, language) do
    normalized_language = normalize_term(language)

    case Repo.get_by(PostTranslation, translation_for: post.id, language: normalized_language) do
      nil -> post_detail(post)
      %PostTranslation{} = translation ->
        post_detail(post)
        |> Map.put("title", translation.title)
        |> Map.put("excerpt", translation.excerpt)
        |> Map.put("content", translation_body(translation))
        |> Map.put("language", translation.language)
        |> Map.put("canonical_language", post.language)
    end
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

  defp post_summary(%Post{} = post) do
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

  defp available_languages(post_id, canonical_language) do
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

  defp post_body(%Post{content: content}) when is_binary(content), do: content

  defp post_body(%Post{} = post) do
    project = Projects.get_project!(post.project_id)
    full_path = Path.join(Projects.project_data_dir(project), post.file_path || "")

    case File.read(full_path) do
      {:ok, contents} ->
        case String.split(contents, "\n---\n", parts: 2) do
          [_frontmatter, body] -> String.trim_trailing(body, "\n")
          _parts -> contents
        end

      {:error, _reason} -> ""
    end
  end

  defp translation_body(%PostTranslation{content: content}) when is_binary(content), do: content

  defp translation_body(%PostTranslation{} = translation) do
    project = Projects.get_project!(translation.project_id)
    full_path = Path.join(Projects.project_data_dir(project), translation.file_path || "")

    case File.read(full_path) do
      {:ok, contents} ->
        case String.split(contents, "\n---\n", parts: 2) do
          [_frontmatter, body] -> String.trim_trailing(body, "\n")
          _parts -> contents
        end

      {:error, _reason} -> ""
    end
  end

  defp tag_post_count(project_id, tag_name) do
    Repo.all(from post in Post, where: post.project_id == ^project_id)
    |> Enum.count(&(tag_name in (&1.tags || [])))
  end

  defp category_post_count(project_id, category) do
    Repo.all(from post in Post, where: post.project_id == ^project_id)
    |> Enum.count(&(category in (&1.categories || [])))
  end

  defp group_rows(_post, []), do: [%{}]

  defp group_rows(post, [dimension | rest]) do
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

  defp search_filters(params) do
    %{}
    |> maybe_put(:category, map_get(params, :category))
    |> maybe_put(:tags, map_get(params, :tags))
    |> maybe_put(:language, map_get(params, :language))
    |> maybe_put(:missing_translation_language, map_get(params, :missingTranslationLanguage))
    |> maybe_put(:year, map_get(params, :year))
    |> maybe_put(:month, map_get(params, :month))
    |> maybe_put(:status, parse_status(map_get(params, :status)))
    |> Map.put(:offset, map_get(params, :offset, 0))
    |> Map.put(:limit, map_get(params, :limit, @page_size))
  end

  defp parse_status(nil), do: nil
  defp parse_status(status) when is_atom(status), do: status
  defp parse_status(status) when is_binary(status), do: String.to_existing_atom(status)

  defp script_validation(content) do
    case BDS.Scripting.validate(content) do
      :ok -> %{valid: true, errors: []}
      {:error, reason} -> %{valid: false, errors: [inspect(reason)]}
    end
  end

  defp parse_script_kind(value) when is_atom(value), do: value
  defp parse_script_kind("macro"), do: :macro
  defp parse_script_kind("utility"), do: :utility
  defp parse_script_kind("transform"), do: :transform

  defp parse_template_kind(value) when is_atom(value), do: value
  defp parse_template_kind("post"), do: :post
  defp parse_template_kind("list"), do: :list
  defp parse_template_kind("not-found"), do: :not_found
  defp parse_template_kind("not_found"), do: :not_found
  defp parse_template_kind("partial"), do: :partial

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)
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

  defp normalize_term(nil), do: ""
  defp normalize_term(value), do: value |> to_string() |> String.downcase()

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_get(map, key, default \\ nil) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> default
    end
  end
end
