defmodule BDS.AI.ChatTools do
  @moduledoc false

  import Ecto.Query

  alias BDS.AI.Chat
  alias BDS.Media, as: MediaContext
  alias BDS.Media.Media
  alias BDS.MCP.Queries
  alias BDS.Posts, as: PostsContext
  alias BDS.Posts.Post
  alias BDS.Posts.PostMedia
  alias BDS.Projects.Project
  alias BDS.Repo
  alias BDS.Search

  @spec execute(String.t(), map(), String.t() | nil) :: map()
  def execute("blog_stats", _arguments, project_id) do
    execute("get_blog_stats", %{}, project_id)
  end

  def execute("get_blog_stats", _arguments, project_id) do
    project_id = project_id || active_project_id()

    %{
      post_count:
        Repo.aggregate(from(post in Post, where: post.project_id == ^project_id), :count, :id),
      media_count:
        Repo.aggregate(from(media in Media, where: media.project_id == ^project_id), :count, :id),
      tag_count: Chat.count_distinct_string_list(Post, :tags, project_id),
      category_count: Chat.count_distinct_string_list(Post, :categories, project_id)
    }
  end

  def execute("check_term", arguments, project_id) do
    project_id = project_id || active_project_id()
    term = normalize_term(arguments["term"])

    posts = Repo.all(from post in Post, where: post.project_id == ^project_id)

    tag_post_count =
      Enum.count(posts, fn post ->
        Enum.any?(post.tags || [], &(normalize_term(&1) == term))
      end)

    category_post_count =
      Enum.count(posts, fn post ->
        Enum.any?(post.categories || [], &(normalize_term(&1) == term))
      end)

    %{
      is_category: category_post_count > 0,
      category_post_count: category_post_count,
      is_tag: tag_post_count > 0,
      tag_post_count: tag_post_count
    }
  end

  def execute("search_posts", arguments, project_id) do
    project_id = project_id || active_project_id()
    filters = search_filters(arguments)

    {:ok, result} = Search.search_posts(project_id, arguments["query"] || "", filters)

    %{
      posts: Enum.map(result.posts, &Queries.post_summary/1),
      total: result.total,
      offset: result.offset,
      limit: result.limit,
      has_more: result.offset + result.limit < result.total
    }
  end

  def execute("read_post_by_slug", arguments, project_id) do
    project_id = project_id || active_project_id()

    case Repo.get_by(Post, project_id: project_id, slug: arguments["slug"]) do
      %Post{} = post -> %{post: Queries.post_detail(post)}
      nil -> %{error: "not_found"}
    end
  end

  def execute("read_post", arguments, project_id) do
    project_id = project_id || active_project_id()

    case Repo.get_by(Post,
           id: arguments["postId"] || arguments["post_id"],
           project_id: project_id
         ) do
      %Post{} = post -> %{post: Queries.post_detail(post)}
      nil -> %{success: false, error: "not_found"}
    end
  end

  def execute("list_posts", arguments, project_id) do
    project_id = project_id || active_project_id()
    limit = normalize_limit(arguments["limit"])
    offset = normalize_offset(arguments["offset"])
    filters = search_filters(arguments) |> Map.merge(%{limit: limit, offset: offset})

    {:ok, result} = Search.search_posts(project_id, "", filters)

    %{
      posts:
        Enum.map(result.posts, fn post ->
          post
          |> Queries.post_summary()
          |> Map.put("url", "/posts/#{post.slug}")
          |> Map.put("updated_at", post.updated_at)
        end),
      total: result.total,
      offset: result.offset,
      limit: result.limit,
      has_more: result.offset + result.limit < result.total
    }
  end

  def execute("list_media", arguments, project_id) do
    project_id = project_id || active_project_id()
    limit = normalize_limit(arguments["limit"])

    Repo.all(
      from(media in Media,
        where: media.project_id == ^project_id,
        order_by: [desc: media.updated_at],
        limit: ^limit,
        select: %{
          id: media.id,
          title: media.title,
          mime_type: media.mime_type,
          filename: media.filename,
          updated_at: media.updated_at
        }
      )
    )
  end

  def execute("get_media", arguments, project_id) do
    project_id = project_id || active_project_id()

    case Repo.get_by(Media,
           id: arguments["mediaId"] || arguments["media_id"],
           project_id: project_id
         ) do
      %Media{} = media -> %{media: media_summary(media)}
      nil -> %{success: false, error: "not_found"}
    end
  end

  def execute("view_image", arguments, project_id) do
    project_id = project_id || active_project_id()
    media_id = arguments["mediaId"] || arguments["media_id"]
    size = arguments["size"] || "medium"

    case Repo.get_by(Media, id: media_id, project_id: project_id) do
      %Media{mime_type: "image/" <> _rest} = media ->
        case thumbnail_data_url(project_id, media, size) do
          nil -> %{success: false, error: "thumbnail_not_available"}
          data_url -> %{success: true, media: media_summary(media), data_url: data_url}
        end

      %Media{} = media ->
        %{success: false, error: "not_image", mime_type: media.mime_type}

      nil ->
        %{success: false, error: "not_found"}
    end
  end

  def execute("update_post_metadata", arguments, project_id) do
    project_id = project_id || active_project_id()
    post_id = arguments["postId"] || arguments["post_id"]

    with %Post{} <- Repo.get_by(Post, id: post_id, project_id: project_id),
         attrs <- metadata_attrs(arguments, ["title", "excerpt", "tags", "categories"]),
         false <- attrs == %{},
         {:ok, post} <- PostsContext.update_post(post_id, attrs) do
      %{success: true, post: Queries.post_detail(post)}
    else
      nil -> %{success: false, error: "not_found"}
      true -> %{success: false, error: "no_updates_provided"}
      {:error, reason} -> %{success: false, error: inspect(reason)}
    end
  end

  def execute("update_media_metadata", arguments, project_id) do
    project_id = project_id || active_project_id()
    media_id = arguments["mediaId"] || arguments["media_id"]

    with %Media{} <- Repo.get_by(Media, id: media_id, project_id: project_id),
         attrs <- metadata_attrs(arguments, ["title", "alt", "caption", "tags"]),
         false <- attrs == %{},
         {:ok, media} <- MediaContext.update_media(media_id, attrs) do
      %{success: true, media: media_summary(media)}
    else
      nil -> %{success: false, error: "not_found"}
      true -> %{success: false, error: "no_updates_provided"}
      {:error, reason} -> %{success: false, error: inspect(reason)}
    end
  end

  def execute("list_tags", _arguments, project_id) do
    project_id = project_id || active_project_id()

    %{
      tags: counted_terms(project_id, :tags),
      count: length(counted_terms(project_id, :tags))
    }
  end

  def execute("list_categories", _arguments, project_id) do
    project_id = project_id || active_project_id()

    %{
      categories: counted_terms(project_id, :categories),
      count: length(counted_terms(project_id, :categories))
    }
  end

  def execute("count_posts", arguments, project_id) do
    project_id = project_id || active_project_id()
    group_by = List.wrap(arguments["groupBy"] || arguments["group_by"]) |> Enum.map(&to_string/1)
    {:ok, result} = Search.search_posts(project_id, "", search_filters(arguments))

    groups =
      result.posts
      |> Enum.flat_map(&Queries.group_rows(&1, group_by))
      |> Enum.group_by(& &1, fn _row -> 1 end)
      |> Enum.map(fn {row, counts} -> Map.put(row, "count", length(counts)) end)
      |> Enum.sort_by(&Map.to_list/1)

    %{groups: groups, total_posts: result.total}
  end

  def execute("get_post_backlinks", arguments, project_id) do
    project_id = project_id || active_project_id()

    case Repo.get_by(Post,
           id: arguments["postId"] || arguments["post_id"],
           project_id: project_id
         ) do
      %Post{} = post ->
        %{success: true, post_id: post.id, linked_by: Queries.linked_posts(post.id, :incoming)}

      nil ->
        %{success: false, error: "not_found"}
    end
  end

  def execute("get_post_outlinks", arguments, project_id) do
    project_id = project_id || active_project_id()

    case Repo.get_by(Post,
           id: arguments["postId"] || arguments["post_id"],
           project_id: project_id
         ) do
      %Post{} = post ->
        %{success: true, post_id: post.id, links_to: Queries.linked_posts(post.id, :outgoing)}

      nil ->
        %{success: false, error: "not_found"}
    end
  end

  def execute("get_post_media", arguments, project_id) do
    project_id = project_id || active_project_id()
    post_id = arguments["postId"] || arguments["post_id"]

    case Repo.get_by(Post, id: post_id, project_id: project_id) do
      %Post{} = post -> %{success: true, post_id: post.id, media: post_media(project_id, post.id)}
      nil -> %{success: false, error: "not_found"}
    end
  end

  def execute("get_media_posts", arguments, project_id) do
    project_id = project_id || active_project_id()
    media_id = arguments["mediaId"] || arguments["media_id"]

    case Repo.get_by(Media, id: media_id, project_id: project_id) do
      %Media{} = media -> %{success: true, media_id: media.id, posts: media_posts(media.id)}
      nil -> %{success: false, error: "not_found"}
    end
  end

  def execute("render_table", arguments, _project_id) do
    %{
      type: "table",
      title: arguments["title"],
      columns: arguments["columns"] || [],
      rows: arguments["rows"] || []
    }
  end

  def execute("render_chart", arguments, _project_id) do
    %{
      type: "chart",
      title: arguments["title"],
      chart_type: arguments["chartType"] || arguments["chart_type"] || "bar",
      series: arguments["series"] || []
    }
  end

  def execute("render_form", arguments, _project_id) do
    %{
      type: "form",
      title: arguments["title"],
      fields: arguments["fields"] || [],
      submit_label: arguments["submit_label"] || arguments["submitLabel"],
      submit_action: arguments["submit_action"] || arguments["submitAction"]
    }
  end

  def execute("render_card", arguments, _project_id) do
    %{
      type: "card",
      title: arguments["title"],
      subtitle: arguments["subtitle"],
      body: arguments["body"],
      actions: arguments["actions"] || []
    }
  end

  def execute("render_metric", arguments, _project_id) do
    %{
      type: "metric",
      label: arguments["label"],
      value: arguments["value"]
    }
  end

  def execute("render_list", arguments, _project_id) do
    %{
      type: "list",
      title: arguments["title"],
      items: arguments["items"] || []
    }
  end

  def execute("render_tabs", arguments, _project_id) do
    %{
      type: "tabs",
      title: arguments["title"],
      tabs: arguments["tabs"] || []
    }
  end

  def execute("render_mindmap", arguments, _project_id) do
    %{
      type: "mindmap",
      title: arguments["title"],
      nodes: arguments["nodes"] || []
    }
  end

  def execute(name, _arguments, _project_id) do
    %{error: "unknown_tool", name: name}
  end

  @spec available_specs(String.t() | nil, map()) :: [map()]
  def available_specs(project_id, capabilities) do
    if capabilities.supports_tool_calls do
      project_tools =
        if is_binary(project_id) do
          [
            %{
              name: "blog_stats",
              spec:
                tool_spec("blog_stats", "Return aggregate blog statistics", %{
                  "type" => "object",
                  "properties" => %{}
                })
            },
            %{
              name: "get_blog_stats",
              spec:
                tool_spec(
                  "get_blog_stats",
                  "Get comprehensive blog statistics: total posts, media count, unique tag count, and unique category count. Use this first when you need to understand the scope of the data.",
                  %{"type" => "object", "properties" => %{}}
                )
            },
            %{
              name: "check_term",
              spec:
                tool_spec(
                  "check_term",
                  "Check whether a term exists as a category, tag, or both. Returns post counts for each. Use before search_posts or list_posts when unsure whether a term is a category or tag.",
                  %{
                    "type" => "object",
                    "properties" => %{"term" => %{"type" => "string"}},
                    "required" => ["term"]
                  }
                )
            },
            %{
              name: "search_posts",
              spec:
                tool_spec(
                  "search_posts",
                  "Search blog posts using full-text search. Can filter by category, tags, language, missing translation language, year, month, or status. Returns paginated concrete post data with titles, slugs, tags, categories, backlinks, and links_to.",
                  post_search_schema(true)
                )
            },
            %{
              name: "read_post",
              spec:
                tool_spec(
                  "read_post",
                  "Read full content and metadata of a specific blog post by ID. Includes backlinks, links_to, tags, categories, excerpt, status, language, and available languages.",
                  %{
                    "type" => "object",
                    "properties" => %{"postId" => %{"type" => "string"}},
                    "required" => ["postId"]
                  }
                )
            },
            %{
              name: "read_post_by_slug",
              spec:
                tool_spec(
                  "read_post_by_slug",
                  "Read full content and metadata of a specific blog post by slug. Includes backlinks, links_to, tags, categories, excerpt, status, language, and available languages.",
                  %{
                    "type" => "object",
                    "properties" => %{"slug" => %{"type" => "string"}},
                    "required" => ["slug"]
                  }
                )
            },
            %{
              name: "list_posts",
              spec:
                tool_spec(
                  "list_posts",
                  "List blog posts with optional filtering by status, category, tags, language, year, or month. Returns paginated concrete post data with titles, slugs, URLs, statuses, tags, categories, backlinks, and links_to. Use for recent, latest, top, or title-list requests.",
                  post_search_schema(false)
                )
            },
            %{
              name: "get_media",
              spec:
                tool_spec(
                  "get_media",
                  "Get information about a specific media file by ID, including title, alt text, caption, tags, filename, MIME type, dimensions, and update time.",
                  media_id_schema()
                )
            },
            %{
              name: "list_media",
              spec:
                tool_spec(
                  "list_media",
                  "List concrete media data in the active project, including titles, filenames, MIME types, and update times.",
                  limit_schema()
                )
            },
            %{
              name: "view_image",
              spec:
                tool_spec(
                  "view_image",
                  "View an image thumbnail as a local data URL for visual inspection. Only works with image media files.",
                  media_id_schema(%{
                    "size" => %{"type" => "string", "enum" => ["small", "medium", "large"]}
                  })
                )
            },
            %{
              name: "update_post_metadata",
              spec:
                tool_spec(
                  "update_post_metadata",
                  "Update metadata for a blog post: title, excerpt, tags, or categories. Does not update post body content.",
                  update_post_metadata_schema()
                )
            },
            %{
              name: "update_media_metadata",
              spec:
                tool_spec(
                  "update_media_metadata",
                  "Update metadata for a media file: title, alt text, caption, or tags.",
                  update_media_metadata_schema()
                )
            },
            %{
              name: "list_tags",
              spec:
                tool_spec(
                  "list_tags",
                  "List all tags used across blog posts with post counts.",
                  %{
                    "type" => "object",
                    "properties" => %{}
                  }
                )
            },
            %{
              name: "list_categories",
              spec:
                tool_spec(
                  "list_categories",
                  "List all categories used across blog posts with post counts.",
                  %{"type" => "object", "properties" => %{}}
                )
            },
            %{
              name: "count_posts",
              spec:
                tool_spec(
                  "count_posts",
                  "Count posts grouped by dimensions such as year, month, tag, category, or status. Use for analytics, distributions, and heat maps without transferring full post content.",
                  count_posts_schema()
                )
            },
            %{
              name: "get_post_backlinks",
              spec:
                tool_spec(
                  "get_post_backlinks",
                  "Get all posts that link to a specific post.",
                  post_id_schema()
                )
            },
            %{
              name: "get_post_outlinks",
              spec:
                tool_spec(
                  "get_post_outlinks",
                  "Get all posts that a specific post links to.",
                  post_id_schema()
                )
            },
            %{
              name: "get_post_media",
              spec:
                tool_spec(
                  "get_post_media",
                  "Get media files linked to a specific post.",
                  post_id_schema()
                )
            },
            %{
              name: "get_media_posts",
              spec:
                tool_spec(
                  "get_media_posts",
                  "Get posts that use a specific media file.",
                  media_id_schema()
                )
            }
          ]
        else
          []
        end

      project_tools ++
        [
          %{
            name: "render_card",
            spec:
              tool_spec(
                "render_card",
                "Render an information card in the chat UI. Use this for displaying a summary, highlight, or actionable item.",
                render_card_schema()
              )
          },
          %{
            name: "render_table",
            spec:
              tool_spec(
                "render_table",
                "Render a data table in the chat UI. Use this when the user asks for tabular data, comparisons, or structured information.",
                render_table_schema()
              )
          },
          %{
            name: "render_chart",
            spec:
              tool_spec(
                "render_chart",
                "Render an interactive chart in the chat UI. Use this when the user asks for a chart, graph, or data visualization. Supports bar, stacked-bar, line, area, pie, donut, and heatmap charts. Use stacked-bar for multi-segment bars and heatmap for grid/matrix visualizations.",
                render_chart_schema()
              )
          },
          %{
            name: "render_form",
            spec:
              tool_spec(
                "render_form",
                "Render an interactive form in the chat UI. Use this when you need to collect structured input from the user.",
                render_form_schema()
              )
          },
          %{
            name: "render_metric",
            spec:
              tool_spec(
                "render_metric",
                "Render a single metric/KPI display in the chat UI. Use this for showing a single important value with a label.",
                render_metric_schema()
              )
          },
          %{
            name: "render_list",
            spec:
              tool_spec(
                "render_list",
                "Render a list of items in the chat UI. Use this for displaying bullet-point style lists, checklists, or simple enumerations.",
                render_list_schema()
              )
          },
          %{
            name: "render_tabs",
            spec:
              tool_spec(
                "render_tabs",
                "Render a tabbed interface in the chat UI. Use this to organize information into multiple tabs that the user can switch between.",
                render_tabs_schema()
              )
          },
          %{
            name: "render_mindmap",
            spec:
              tool_spec(
                "render_mindmap",
                "Render a mind map diagram in the chat UI. Use this when the user asks for a mind map, concept map, topic tree, brainstorming diagram, or hierarchical overview of ideas.",
                render_mindmap_schema()
              )
          }
        ]
    else
      []
    end
  end

  defp tool_spec(name, description, parameters) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => parameters
      }
    }
  end

  defp limit_schema do
    %{
      "type" => "object",
      "properties" => %{
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
      }
    }
  end

  defp post_search_schema(require_query) do
    schema = %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string"},
        "status" => %{"type" => "string", "enum" => ["draft", "published", "archived"]},
        "category" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
        "language" => %{"type" => "string"},
        "missingTranslationLanguage" => %{"type" => "string"},
        "year" => %{"type" => "integer"},
        "month" => %{"type" => "integer", "minimum" => 1, "maximum" => 12},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
        "offset" => %{"type" => "integer", "minimum" => 0}
      }
    }

    if require_query, do: Map.put(schema, "required", ["query"]), else: schema
  end

  defp count_posts_schema do
    %{
      "type" => "object",
      "properties" => %{
        "groupBy" => %{
          "type" => "array",
          "items" => %{
            "type" => "string",
            "enum" => ["year", "month", "tag", "category", "status"]
          }
        },
        "year" => %{"type" => "integer"},
        "month" => %{"type" => "integer", "minimum" => 1, "maximum" => 12},
        "status" => %{"type" => "string", "enum" => ["draft", "published", "archived"]},
        "category" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["groupBy"]
    }
  end

  defp post_id_schema do
    %{
      "type" => "object",
      "properties" => %{"postId" => %{"type" => "string"}},
      "required" => ["postId"]
    }
  end

  defp media_id_schema(extra_properties \\ %{}) do
    %{
      "type" => "object",
      "properties" => Map.merge(%{"mediaId" => %{"type" => "string"}}, extra_properties),
      "required" => ["mediaId"]
    }
  end

  defp update_post_metadata_schema do
    %{
      "type" => "object",
      "properties" => %{
        "postId" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "excerpt" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
        "categories" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["postId"]
    }
  end

  defp update_media_metadata_schema do
    %{
      "type" => "object",
      "properties" => %{
        "mediaId" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "alt" => %{"type" => "string"},
        "caption" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["mediaId"]
    }
  end

  defp render_table_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "Optional table title"},
        "columns" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Column header names"
        },
        "rows" => %{
          "type" => "array",
          "items" => %{"type" => "array", "items" => %{"type" => "string"}},
          "description" => "Table rows, each row is an array of cell values"
        }
      }
    }
  end

  defp render_chart_schema do
    %{
      "type" => "object",
      "properties" => %{
        "chartType" => %{
          "type" => "string",
          "enum" => ["bar", "stacked-bar", "line", "area", "pie", "donut", "heatmap"],
          "description" =>
            "The type of chart to render. Use stacked-bar for multi-segment bars. Use heatmap for grid/matrix visualizations."
        },
        "title" => %{"type" => "string", "description" => "Optional chart title"},
        "series" => %{
          "type" => "array",
          "description" => "Array of data points.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "label" => %{"type" => "string", "description" => "Data point label"},
              "value" => %{"type" => "number", "description" => "Data point value"},
              "segments" => %{
                "type" => "array",
                "description" =>
                  "Segments within this data point. Required for stacked-bar and heatmap charts.",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "label" => %{"type" => "string"},
                    "value" => %{"type" => "number"}
                  },
                  "required" => ["label", "value"]
                }
              }
            },
            "required" => ["label"]
          }
        }
      },
      "required" => ["chartType", "series"]
    }
  end

  defp render_form_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "fields" => %{"type" => "array"},
        "submitLabel" => %{"type" => "string"},
        "submitAction" => %{"type" => "string"}
      }
    }
  end

  defp render_card_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "subtitle" => %{"type" => "string"},
        "body" => %{"type" => "string"},
        "actions" => %{"type" => "array"}
      }
    }
  end

  defp render_metric_schema do
    %{
      "type" => "object",
      "properties" => %{
        "label" => %{"type" => "string"},
        "value" => %{"type" => "string"}
      }
    }
  end

  defp render_list_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "items" => %{"type" => "array"}
      }
    }
  end

  defp render_tabs_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "tabs" => %{"type" => "array"}
      }
    }
  end

  defp render_mindmap_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "nodes" => %{"type" => "array"}
      }
    }
  end

  defp normalize_limit(value) when is_integer(value) and value > 0 and value <= 50, do: value
  defp normalize_limit(_value), do: 10

  defp normalize_offset(value) when is_integer(value) and value >= 0, do: value
  defp normalize_offset(_value), do: 0

  defp search_filters(arguments) do
    %{}
    |> maybe_put(:category, arguments["category"])
    |> maybe_put(:tags, arguments["tags"])
    |> maybe_put(:language, arguments["language"])
    |> maybe_put(:missing_translation_language, arguments["missingTranslationLanguage"])
    |> maybe_put(:year, arguments["year"])
    |> maybe_put(:month, arguments["month"])
    |> maybe_put(:status, BDS.BoundedAtoms.post_status(arguments["status"]))
    |> Map.put(:offset, normalize_offset(arguments["offset"]))
    |> Map.put(:limit, normalize_limit(arguments["limit"]))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp counted_terms(project_id, field) do
    Repo.all(
      from post in Post, where: post.project_id == ^project_id, select: field(post, ^field)
    )
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.map(fn {term, count} -> %{name: term, count: count} end)
    |> Enum.sort_by(&String.downcase(to_string(&1.name)))
  end

  defp metadata_attrs(arguments, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      maybe_put(acc, String.to_atom(key), arguments[key])
    end)
  end

  defp media_summary(%Media{} = media) do
    %{
      id: media.id,
      filename: media.filename,
      original_name: media.original_name,
      mime_type: media.mime_type,
      size: media.size,
      width: media.width,
      height: media.height,
      title: media.title,
      alt: media.alt,
      caption: media.caption,
      author: media.author,
      language: media.language,
      tags: media.tags || [],
      created_at: media.created_at,
      updated_at: media.updated_at
    }
  end

  defp post_media(project_id, post_id) do
    Repo.all(
      from media in Media,
        join: post_media in PostMedia,
        on: post_media.media_id == media.id,
        where: post_media.project_id == ^project_id and post_media.post_id == ^post_id,
        order_by: [asc: post_media.sort_order, asc: media.updated_at]
    )
    |> Enum.map(&media_summary/1)
  end

  defp media_posts(media_id) do
    MediaContext.list_linked_posts(media_id)
    |> Enum.map(fn post ->
      %{"id" => post.post_id, "title" => post.title, "sort_order" => post.sort_order}
    end)
  end

  defp thumbnail_data_url(project_id, media, size) do
    project = Repo.get!(Project, project_id)
    size_key = thumbnail_size(size)
    relative_path = MediaContext.thumbnail_paths(media)[size_key]
    absolute_path = Path.join(project.data_path, relative_path || "")

    with true <- is_binary(relative_path),
         true <- File.exists?(absolute_path),
         {:ok, binary} <- File.read(absolute_path) do
      "data:#{thumbnail_mime(absolute_path)};base64," <> Base.encode64(binary)
    else
      _other -> nil
    end
  end

  defp thumbnail_size("small"), do: :small
  defp thumbnail_size("large"), do: :large
  defp thumbnail_size(_size), do: :medium

  defp thumbnail_mime(path) do
    case Path.extname(path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _other -> "application/octet-stream"
    end
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp normalize_term(value), do: value |> to_string() |> String.downcase()

  defp active_project_id do
    Repo.one(from(project in Project, where: project.is_active == true, select: project.id))
  end
end
