defmodule BDS.MCP.Tools do
  @moduledoc false

  import Ecto.Query
  import BDS.MCP.Util, only: [maybe_put: 3, map_get: 3, sanitize: 1, normalize_term: 1]

  alias BDS.MCP.ProposalStore
  alias BDS.MCP.Queries
  alias BDS.Media
  alias BDS.Media.Media, as: MediaAsset
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Scripts
  alias BDS.Search
  alias BDS.Templates

  @proposal_ttl_app_ms 30 * 60 * 1000

  @typedoc "Tool descriptor returned by `list/0`."
  @type descriptor :: %{name: String.t(), annotations: map()}

  @spec list() :: [descriptor()]
  def list do
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

  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call(name, params) when is_binary(name) and is_map(params) do
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

  @spec validate_template(String.t()) :: {:ok, %{valid: boolean(), errors: [String.t()]}}
  def validate_template(source) when is_binary(source) do
    case Liquex.parse(source) do
      {:ok, _ast} ->
        {:ok, %{valid: true, errors: []}}

      {:error, reason, line} ->
        {:ok, %{valid: false, errors: ["#{inspect(reason)} at line #{line}"]}}
    end
  end

  defp tool(name, read_only) do
    %{
      name: name,
      annotations: %{"readOnlyHint" => read_only, "destructiveHint" => false}
    }
  end

  defp check_term(%{"term" => term}), do: check_term(%{term: term})

  defp check_term(%{term: term}) do
    project = Queries.active_project!()
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
    project = Queries.active_project!()
    filters = Queries.search_filters(params)
    query = map_get(params, :query, "")
    {:ok, result} = Search.search_posts(project.id, query, filters)

    posts = Enum.map(result.posts, &Queries.post_summary/1)

    %{
      "posts" => posts,
      "total" => result.total,
      "offset" => result.offset,
      "limit" => result.limit,
      "has_more" => result.offset + result.limit < result.total
    }
  end

  defp count_posts(params) do
    project = Queries.active_project!()
    group_by = map_get(params, :groupBy, []) |> Enum.map(&to_string/1)
    filters = Queries.search_filters(params)
    {:ok, result} = Search.search_posts(project.id, "", filters)

    groups =
      result.posts
      |> Enum.flat_map(&Queries.group_rows(&1, group_by))
      |> Enum.group_by(& &1, fn _row -> 1 end)
      |> Enum.map(fn {row, counts} -> Map.put(row, "count", length(counts)) end)
      |> Enum.sort_by(&Map.to_list/1)

    %{"groups" => groups, "total_posts" => result.total}
  end

  defp read_post_by_slug(%{"slug" => slug} = params),
    do: read_post_by_slug(Map.put_new(params, :slug, slug))

  defp read_post_by_slug(%{slug: slug} = params) do
    project = Queries.active_project!()

    case Repo.get_by(Post, project_id: project.id, slug: slug) do
      nil ->
        {:error, :not_found}

      %Post{} = post ->
        payload =
          case map_get(params, :language, nil) do
            nil ->
              Queries.post_detail(post)

            "" ->
              Queries.post_detail(post)

            language ->
              if normalize_term(language) == normalize_term(post.language) do
                Queries.post_detail(post)
              else
                Queries.translated_post_detail(post, language)
              end
          end

        {:ok, %{"post" => payload}}
    end
  end

  defp draft_post(params) do
    project = Queries.active_project!()

    attrs = %{
      project_id: project.id,
      title: map_get(params, :title, ""),
      content: map_get(params, :content, ""),
      excerpt: map_get(params, :excerpt, nil),
      tags: map_get(params, :tags, []),
      categories: map_get(params, :categories, []),
      author: map_get(params, :author, nil)
    }

    with {:ok, post} <- Posts.create_post(attrs) do
      proposal =
        ProposalStore.create("draft_post", %{"post_id" => post.id},
          entity_id: post.id,
          ttl_ms: @proposal_ttl_app_ms
        )

      {:ok, %{"proposal_id" => proposal.id, "post" => sanitize(post)}}
    end
  end

  defp propose_script(params) do
    project = Queries.active_project!()
    content = map_get(params, :content, "")

    with validation <- script_validation(content),
         {:ok, script} <-
           Scripts.create_script(%{
             project_id: project.id,
             title: map_get(params, :title, ""),
             kind: parse_script_kind(map_get(params, :kind, nil)),
             content: content,
             entrypoint: map_get(params, :entrypoint, nil)
           }) do
      proposal =
        ProposalStore.create("propose_script", %{"script_id" => script.id},
          entity_id: script.id,
          ttl_ms: @proposal_ttl_app_ms
        )

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
    project = Queries.active_project!()
    content = map_get(params, :content, "")
    {:ok, validation} = validate_template(content)

    with {:ok, template} <-
           Templates.create_template(%{
             project_id: project.id,
             title: map_get(params, :title, ""),
             kind: parse_template_kind(map_get(params, :kind, nil)),
             content: content
           }) do
      proposal =
        ProposalStore.create("propose_template", %{"template_id" => template.id},
          entity_id: template.id,
          ttl_ms: @proposal_ttl_app_ms
        )

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
    media_id = map_get(params, :mediaId, nil)

    case Repo.get(MediaAsset, media_id) do
      nil ->
        {:error, :not_found}

      %MediaAsset{} = media ->
        changes =
          %{}
          |> maybe_put("title", map_get(params, :title, nil))
          |> maybe_put("alt", map_get(params, :alt, nil))
          |> maybe_put("caption", map_get(params, :caption, nil))
          |> maybe_put("tags", map_get(params, :tags, nil))

        proposal =
          ProposalStore.create(
            "propose_media_metadata",
            %{"media_id" => media_id, "changes" => changes},
            entity_id: media_id,
            ttl_ms: @proposal_ttl_app_ms
          )

        {:ok,
         %{"proposal_id" => proposal.id, "current" => sanitize(media), "proposed" => changes}}
    end
  end

  defp propose_post_metadata(params) do
    post_id = map_get(params, :postId, nil)

    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{} = post ->
        changes =
          %{}
          |> maybe_put("title", map_get(params, :title, nil))
          |> maybe_put("excerpt", map_get(params, :excerpt, nil))
          |> maybe_put("tags", map_get(params, :tags, nil))
          |> maybe_put("categories", map_get(params, :categories, nil))

        proposal =
          ProposalStore.create(
            "propose_post_metadata",
            %{"post_id" => post_id, "changes" => changes},
            entity_id: post_id,
            ttl_ms: @proposal_ttl_app_ms
          )

        {:ok, %{"proposal_id" => proposal.id, "current" => sanitize(post), "proposed" => changes}}
    end
  end

  defp accept_proposal(params) do
    proposal_id = map_get(params, :proposalId, nil)

    case ProposalStore.get(proposal_id) do
      nil ->
        {:error, :not_found}

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
              Media.update_media(proposal.data["media_id"], proposal.data["changes"] || %{})

            "propose_post_metadata" ->
              Posts.update_post(proposal.data["post_id"], proposal.data["changes"] || %{})

            _other ->
              {:error, :unsupported_proposal}
          end

        case result do
          {:ok, value} ->
            _ = ProposalStore.mark_accepted(proposal_id)
            {:ok, %{"success" => true, "message" => "accepted", "result" => sanitize(value)}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp discard_proposal(params) do
    proposal_id = map_get(params, :proposalId, nil)

    case ProposalStore.get(proposal_id) do
      nil ->
        {:error, :not_found}

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
            _ = ProposalStore.mark_discarded(proposal_id)
            {:ok, %{"success" => true, "message" => "discarded"}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

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
end
