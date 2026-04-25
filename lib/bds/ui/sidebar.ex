defmodule BDS.UI.Sidebar do
  @moduledoc false

  import Ecto.Query

  alias BDS.AI.ChatConversation
  alias BDS.Media.Media
  alias BDS.Posts.Post
  alias BDS.Posts.Translation
  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Tags.Tag
  alias BDS.Templates.Template

  @page_category "page"

  def snapshot(nil), do: empty_snapshot()

  def snapshot(project_id) when is_binary(project_id) do
    posts = list_posts(project_id)
    translation_counts = translation_counts(project_id)
    media_items = list_media(project_id)
    scripts = list_scripts(project_id)
    templates = list_templates(project_id)
    tags = list_tags(project_id)
    conversations = list_conversations()

    %{
      "posts" => posts_view(posts, translation_counts, false),
      "pages" => posts_view(posts, translation_counts, true),
      "media" => media_view(media_items),
      "scripts" => entity_list_view("Scripts", "Automation helpers", "scripts", scripts),
      "templates" =>
        entity_list_view("Templates", "Site rendering", "templates", templates),
      "tags" => tags_nav_view(tags),
      "chat" => entity_list_view("Chat", "AI conversations", "chat", conversations),
      "import" => entity_list_view("Import", "Import definitions", "import", []),
      "git" => git_view(),
      "settings" => settings_nav_view()
    }
  end

  def empty_snapshot do
    %{
      "posts" => posts_view([], %{}, false),
      "pages" => posts_view([], %{}, true),
      "media" => media_view([]),
      "scripts" => entity_list_view("Scripts", "Automation helpers", "scripts", []),
      "templates" => entity_list_view("Templates", "Site rendering", "templates", []),
      "tags" => tags_nav_view([]),
      "chat" => entity_list_view("Chat", "AI conversations", "chat", []),
      "import" => entity_list_view("Import", "Import definitions", "import", []),
      "git" => git_view(),
      "settings" => settings_nav_view()
    }
  end

  defp posts_view(posts, translation_counts, pages?) do
    filtered_posts = Enum.filter(posts, &(page_post?(&1) == pages?))
    grouped_posts = group_posts(filtered_posts)

    %{
      title: if(pages?, do: "Pages", else: "Posts"),
      subtitle: if(pages?, do: "Standalone pages", else: "Drafts, published entries, and archive history"),
      layout: "post_list",
      empty_message: if(pages?, do: "No items", else: "No items"),
      sections: [
        build_post_section("Drafts", :draft, grouped_posts.draft, translation_counts, false),
        build_post_section("Published", :published, grouped_posts.published, translation_counts, true),
        build_post_section("Archived", :archived, grouped_posts.archived, translation_counts, false)
      ]
    }
  end

  defp media_view(media_items) do
    %{
      title: "Media",
      subtitle: "Images and files",
      layout: "media_grid",
      empty_message: "No items",
      items:
        Enum.map(media_items, fn media ->
          %{
            id: media.id,
            title: display_media_title(media),
            meta: media_size_label(media.size),
            mime_type: media.mime_type,
            route: "media"
          }
        end)
    }
  end

  defp tags_nav_view(tags) do
    %{
      title: "Tags",
      subtitle: "Tag management",
      layout: "nav_list",
      items: [
        %{id: "tags-cloud", title: "Tag Cloud", icon: "☁️", route: "tags"},
        %{id: "tags-manage", title: "Create / Edit", icon: "✏️", route: "tags"},
        %{id: "tags-merge", title: "Merge Tags", icon: "🔀", route: "tags"}
      ],
      summary_badge: length(tags)
    }
  end

  defp settings_nav_view do
    %{
      title: "Settings",
      subtitle: "Project and publishing",
      layout: "nav_list",
      items: [
        %{id: "settings-project", title: "Project", icon: "📁", route: "settings"},
        %{id: "settings-editor", title: "Editor", icon: "📝", route: "settings"},
        %{id: "settings-content", title: "Content", icon: "📋", route: "settings"},
        %{id: "settings-ai", title: "AI", icon: "🤖", route: "settings"},
        %{id: "settings-technology", title: "Technology", icon: "⚙️", route: "settings"},
        %{id: "settings-publishing", title: "Publishing", icon: "🚀", route: "settings"},
        %{id: "settings-data", title: "Data", icon: "🗄️", route: "settings"},
        %{id: "settings-mcp", title: "MCP", icon: "🔌", route: "settings"},
        %{id: "settings-style", title: "Style", icon: "🎨", route: "style"}
      ]
    }
  end

  defp git_view do
    %{
      title: "Git",
      subtitle: "Working tree and history",
      layout: "entity_list",
      empty_message: "No items",
      items: [
        %{id: "git-working-tree", title: "Working tree", meta: "Working tree and history", route: "git_diff", updated_at: nil}
      ]
    }
  end

  defp entity_list_view(title, subtitle, route, items) do
    %{
      title: title,
      subtitle: subtitle,
      layout: "entity_list",
      empty_message: "No items",
      items:
        Enum.map(items, fn item ->
          %{
            id: item.id,
            title: item.title,
            meta: Map.get(item, :meta),
            updated_at: Map.get(item, :updated_at),
            route: route
          }
        end)
    }
  end

  defp build_post_section(title, status, posts, translation_counts, published_meta?) do
    %{
      id: Atom.to_string(status),
      title: title,
      status: Atom.to_string(status),
      count: length(posts),
      items:
        Enum.map(posts, fn post ->
          %{
            id: post.id,
            title: display_post_title(post),
            categories: post.categories || [],
            language_count: 1 + Map.get(translation_counts, post.id, 0),
            meta_timestamp: if(published_meta?, do: post.published_at || post.updated_at, else: post.updated_at),
            route: "post"
          }
        end)
    }
  end

  defp list_posts(project_id) do
    Repo.all(
      from post in Post,
        where: post.project_id == ^project_id,
        order_by: [desc: post.updated_at, desc: post.created_at],
        select: %{
          id: post.id,
          title: post.title,
          slug: post.slug,
          status: post.status,
          categories: post.categories,
          updated_at: post.updated_at,
          published_at: post.published_at
        }
    )
  end

  defp translation_counts(project_id) do
    Repo.all(
      from translation in Translation,
        where: translation.project_id == ^project_id,
        group_by: translation.translation_for,
        select: {translation.translation_for, count(translation.id)}
    )
    |> Map.new()
  end

  defp list_media(project_id) do
    Repo.all(
      from media in Media,
        where: media.project_id == ^project_id,
        order_by: [desc: media.updated_at, desc: media.created_at],
        select: %{
          id: media.id,
          title: media.title,
          original_name: media.original_name,
          mime_type: media.mime_type,
          size: media.size
        }
    )
  end

  defp list_scripts(project_id) do
    Repo.all(
      from script in Script,
        where: script.project_id == ^project_id,
        order_by: [desc: script.updated_at, desc: script.created_at],
        select: %{id: script.id, title: script.title, updated_at: script.updated_at}
    )
  end

  defp list_templates(project_id) do
    Repo.all(
      from template in Template,
        where: template.project_id == ^project_id,
        order_by: [desc: template.updated_at, desc: template.created_at],
        select: %{id: template.id, title: template.title, updated_at: template.updated_at}
    )
  end

  defp list_tags(project_id) do
    Repo.all(
      from tag in Tag,
        where: tag.project_id == ^project_id,
        order_by: [asc: tag.name],
        select: %{id: tag.id, title: tag.name, updated_at: tag.updated_at}
    )
  end

  defp list_conversations do
    Repo.all(
      from conversation in ChatConversation,
        order_by: [desc: conversation.updated_at, desc: conversation.created_at],
        select: %{id: conversation.id, title: conversation.title, updated_at: conversation.updated_at}
    )
  end

  defp group_posts(posts) do
    Enum.reduce(posts, %{draft: [], published: [], archived: []}, fn post, acc ->
      case post.status do
        :draft -> %{acc | draft: acc.draft ++ [post]}
        :published -> %{acc | published: acc.published ++ [post]}
        :archived -> %{acc | archived: acc.archived ++ [post]}
        _other -> acc
      end
    end)
  end

  defp page_post?(post) do
    Enum.any?(post.categories || [], &(String.downcase(to_string(&1)) == @page_category))
  end

  defp display_post_title(post) do
    cond do
      present?(post.title) -> post.title
      present?(post.slug) -> post.slug
      true -> "Untitled"
    end
  end

  defp display_media_title(media) do
    if present?(media.title), do: media.title, else: media.original_name || ""
  end

  defp media_size_label(size) when is_integer(size) and size < 1024, do: "#{size} B"

  defp media_size_label(size) when is_integer(size) and size < 1024 * 1024 do
    :erlang.float_to_binary(size / 1024, decimals: 1) <> " KB"
  end

  defp media_size_label(size) when is_integer(size) do
    :erlang.float_to_binary(size / (1024 * 1024), decimals: 1) <> " MB"
  end

  defp media_size_label(_size), do: "0 B"

  defp present?(value), do: value not in [nil, ""]
end
