defmodule BDS.UI.ShellPage do
  @moduledoc false

  alias BDS.UI.MenuBar
  alias BDS.UI.Registry
  alias BDS.UI.Session
  alias BDS.UI.Workbench

  def render do
    bootstrap = bootstrap()

    [
      "<!DOCTYPE html>",
      "<html lang=\"en\">",
      "<head>",
      "  <meta charset=\"utf-8\">",
      "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
      "  <title>Blogging Desktop Server</title>",
      "  <link rel=\"stylesheet\" href=\"/assets/app.css\">",
      "</head>",
      "<body>",
      "  <div class=\"app\" id=\"bds-shell-app\">",
      "    <div class=\"window-titlebar\" data-region=\"title-bar\"></div>",
      "    <div class=\"app-main\">",
      "      <aside class=\"activity-bar\" data-region=\"activity-bar\"></aside>",
      "      <section class=\"sidebar-shell\" data-testid=\"sidebar-shell\">",
      "        <div class=\"sidebar\" data-region=\"sidebar\"></div>",
      "        <div class=\"resizable-panel-divider sidebar-divider\" data-resize=\"sidebar\" data-role=\"resize-handle\"></div>",
      "      </section>",
      "      <main class=\"app-content\" data-region=\"content\">",
      "        <div class=\"tab-bar\" data-region=\"tab-bar\"></div>",
      "        <section class=\"editor-shell\" data-region=\"editor\"></section>",
      "        <section class=\"panel-shell\" data-region=\"panel\"></section>",
      "      </main>",
      "      <section class=\"assistant-sidebar-shell\" data-testid=\"assistant-shell\">",
      "        <div class=\"resizable-panel-divider assistant-divider\" data-resize=\"assistant\" data-role=\"resize-handle\"></div>",
      "        <aside class=\"assistant-sidebar\" data-region=\"assistant-sidebar\"></aside>",
      "      </section>",
      "    </div>",
      "    <footer class=\"status-bar\" data-region=\"status-bar\"></footer>",
      "  </div>",
      "  <script id=\"bds-shell-bootstrap\" type=\"application/json\">#{Jason.encode!(bootstrap)}</script>",
      "  <script src=\"/assets/app.js\"></script>",
      "</body>",
      "</html>"
    ]
    |> Enum.join("\n")
  end

  defp bootstrap do
    workbench = Workbench.new()

    %{
      title: Application.get_env(:bds, :desktop)[:title] || "Blogging Desktop Server",
      registry: %{
        sidebar_views: Enum.map(Registry.sidebar_views(), &encode_sidebar_view/1),
        editor_routes: Enum.map(Registry.editor_routes(), &encode_editor_route/1),
        default_sidebar_view: Atom.to_string(Registry.default_sidebar_view())
      },
      menu_groups: Enum.map(MenuBar.default_groups(), &encode_menu_group/1),
      session: Session.serialize(workbench),
      content: %{
        sidebar: sidebar_content(),
        dashboard: dashboard_content(),
        assistant_cards: assistant_cards(),
        editor_meta: editor_meta()
      },
      status:
        Workbench.status_bar(workbench,
          post_count: 42,
          media_count: 18,
          theme_badge: "desktop-shell",
          ui_language: "en",
          offline_mode: true,
          running_task_message: "Desktop shell ready",
          running_task_overflow: 0,
          git_badge_count: 3
        )
    }
  end

  defp encode_sidebar_view(view) do
    %{
      id: Atom.to_string(view.id),
      label: normalize_view_label(view.id, view.label),
      activity_group: Atom.to_string(view.activity_group),
      editor_route: Atom.to_string(view.editor_route),
      entity_tab: Map.get(view, :entity_tab, false),
      singleton: Map.get(view, :singleton, false)
    }
  end

  defp encode_editor_route(route) do
    %{
      id: Atom.to_string(route.id),
      singleton: route.singleton,
      entity_tab: route.entity_tab,
      title: route.title
    }
  end

  defp encode_menu_group(group) do
    %{
      id: Atom.to_string(group.id),
      label: humanize(group.id),
      items:
        Enum.map(group.items, fn item ->
          %{id: Atom.to_string(item.id), label: humanize(item.id)}
        end)
    }
  end

  defp sidebar_content do
    %{
      "posts" => %{
        title: "Posts",
        subtitle: "Drafts, published entries, and archive history",
        sections: [
          %{
            title: "Drafts",
            items: [
              %{id: "post-welcome", title: "Welcome to bDS2", meta: "Updated today", badge: "draft", route: "post"},
              %{id: "post-launch-plan", title: "Launch plan", meta: "Updated yesterday", badge: "draft", route: "post"}
            ]
          },
          %{
            title: "Published",
            items: [
              %{id: "post-roadmap", title: "Roadmap", meta: "Published Feb 10, 2026", badge: "2 langs", route: "post"}
            ]
          },
          %{
            title: "Archived",
            items: [
              %{id: "post-retrospective", title: "Retrospective", meta: "Archived Jan 12, 2026", badge: "archive", route: "post"}
            ]
          }
        ]
      },
      "pages" => simple_list_view("Pages", "Standalone pages", [
        %{id: "page-about", title: "About", meta: "Static page", route: "post"},
        %{id: "page-contact", title: "Contact", meta: "Static page", route: "post"}
      ]),
      "media" => simple_list_view("Media", "Images and files", [
        %{id: "media-hero", title: "hero-shot.jpg", meta: "Image asset", route: "media"},
        %{id: "media-banner", title: "launch-banner.png", meta: "Image asset", route: "media"}
      ]),
      "scripts" => simple_list_view("Scripts", "Automation helpers", [
        %{id: "script-import", title: "Import posts", meta: "Lua utility", route: "scripts"},
        %{id: "script-sync", title: "Sync tags", meta: "Lua utility", route: "scripts"}
      ]),
      "templates" => simple_list_view("Templates", "Site rendering", [
        %{id: "template-post", title: "post.liquid", meta: "Post template", route: "templates"},
        %{id: "template-list", title: "list.liquid", meta: "List template", route: "templates"}
      ]),
      "tags" => simple_list_view("Tags", "Tag management", [
        %{id: "tag-launch", title: "launch", meta: "12 posts", route: "tags"},
        %{id: "tag-writing", title: "writing", meta: "7 posts", route: "tags"}
      ]),
      "chat" => simple_list_view("Chat", "AI conversations", [
        %{id: "chat-planning", title: "Planning session", meta: "Offline gated", route: "chat"},
        %{id: "chat-translation", title: "Translation QA", meta: "Offline gated", route: "chat"}
      ]),
      "import" => simple_list_view("Import", "Import definitions", [
        %{id: "import-wordpress", title: "WordPress import", meta: "Ready", route: "import"}
      ]),
      "git" => simple_list_view("Git", "Working tree and history", [
        %{id: "git-working-tree", title: "Working tree", meta: "3 changed files", route: "git_diff"}
      ]),
      "settings" => simple_list_view("Settings", "Project and publishing", [
        %{id: "settings-project", title: "Project", meta: "Paths and defaults", route: "settings"},
        %{id: "settings-ai", title: "AI", meta: "Offline controls", route: "settings"}
      ])
    }
  end

  defp simple_list_view(title, subtitle, items) do
    %{title: title, subtitle: subtitle, sections: [%{title: title, items: items}]}
  end

  defp dashboard_content do
    %{
      title: "Dashboard",
      subtitle: "Desktop workbench shell wired through Elixir",
      summary_cards: [
        %{label: "Posts", value: "42", detail: "Across draft, published, and archive"},
        %{label: "Media", value: "18", detail: "Images and documents indexed"},
        %{label: "Tasks", value: "1", detail: "One background action visible in the status bar"}
      ],
      checklist: [
        "Native menu groups mirror the old application shell",
        "Sidebar, tabs, panel, and assistant panes are inspectable DOM regions",
        "Automation can boot the shell in a separate process and capture screenshots"
      ]
    }
  end

  defp assistant_cards do
    [
      %{label: "Offline Gate", text: "Automatic AI actions stay gated by airplane mode."},
      %{label: "Filesystem Sync", text: "Metadata flush, diffing, and rebuild hooks still need editor wiring."},
      %{label: "Desktop Runtime", text: "The app window is now served from the Elixir shell renderer."}
    ]
  end

  defp editor_meta do
    %{
      dashboard: [
        %{label: "Status", value: "Workbench shell ready"},
        %{label: "Mode", value: "Offline"},
        %{label: "Main Language", value: "en"}
      ]
    }
  end

  defp normalize_view_label(:chat, _label), do: "Chat"
  defp normalize_view_label(:git, _label), do: "Git"
  defp normalize_view_label(_id, label), do: label

  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
