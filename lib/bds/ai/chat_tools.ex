defmodule BDS.AI.ChatTools do
  @moduledoc false

  import Ecto.Query

  alias BDS.AI.Chat
  alias BDS.Media.Media
  alias BDS.Posts.Post
  alias BDS.Projects.Project
  alias BDS.Repo

  @spec execute(String.t(), map(), String.t() | nil) :: map()
  def execute("blog_stats", _arguments, project_id) do
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

  def execute("list_posts", arguments, project_id) do
    limit = normalize_limit(arguments["limit"])

    Repo.all(
      from(post in Post,
        where: post.project_id == ^project_id,
        order_by: [desc: post.updated_at],
        limit: ^limit,
        select: %{id: post.id, title: post.title, slug: post.slug, status: post.status}
      )
    )
  end

  def execute("list_media", arguments, project_id) do
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
          filename: media.filename
        }
      )
    )
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
      chart_type: arguments["chart_type"] || "bar",
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
              name: "list_posts",
              spec:
                tool_spec("list_posts", "List recent posts in the active project", limit_schema())
            },
            %{
              name: "list_media",
              spec:
                tool_spec(
                  "list_media",
                  "List recent media items in the active project",
                  limit_schema()
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
              tool_spec("render_card", "Return a structured card payload", render_card_schema())
          },
          %{
            name: "render_table",
            spec:
              tool_spec(
                "render_table",
                "Return a structured table payload",
                render_table_schema()
              )
          },
          %{
            name: "render_chart",
            spec:
              tool_spec(
                "render_chart",
                "Return a structured chart payload",
                render_chart_schema()
              )
          },
          %{
            name: "render_form",
            spec:
              tool_spec("render_form", "Return a structured form payload", render_form_schema())
          },
          %{
            name: "render_metric",
            spec:
              tool_spec(
                "render_metric",
                "Return a structured metric payload",
                render_metric_schema()
              )
          },
          %{
            name: "render_list",
            spec:
              tool_spec("render_list", "Return a structured list payload", render_list_schema())
          },
          %{
            name: "render_tabs",
            spec:
              tool_spec("render_tabs", "Return a structured tabs payload", render_tabs_schema())
          },
          %{
            name: "render_mindmap",
            spec:
              tool_spec(
                "render_mindmap",
                "Return a structured mindmap payload",
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

  defp render_table_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "columns" => %{"type" => "array"},
        "rows" => %{"type" => "array"}
      }
    }
  end

  defp render_chart_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "chart_type" => %{"type" => "string"},
        "series" => %{"type" => "array"}
      }
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

  defp active_project_id do
    Repo.one(from(project in Project, where: project.is_active == true, select: project.id))
  end
end
