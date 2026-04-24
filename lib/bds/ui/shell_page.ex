defmodule BDS.UI.ShellPage do
  @moduledoc false

  alias BDS.UI.MenuBar
  alias BDS.UI.Registry
  alias BDS.UI.Session
  alias BDS.UI.Workbench

  def render do
    bootstrap =
      %{
        registry: %{
          sidebar_views: Registry.sidebar_views(),
          editor_routes: Registry.editor_routes(),
          default_sidebar_view: Registry.default_sidebar_view()
        },
        menu_groups: MenuBar.default_groups(),
        session: Session.serialize(Workbench.new(panel_visible: true)),
        status: %{
          post_count: 12,
          media_count: 34,
          theme_badge: "zinc",
          ui_language: "en",
          offline_mode: true,
          running_task_message: "Building starter shell",
          running_task_overflow: 1,
          git_badge_count: 7
        }
      }

    [
      "<!DOCTYPE html>",
      "<html lang=\"en\">",
      "<head>",
      "  <meta charset=\"utf-8\">",
      "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
      "  <title>bDS Shell</title>",
      "  <link rel=\"stylesheet\" href=\"./app.css\">",
      "</head>",
      "<body>",
      "  <div id=\"bds-shell-app\">",
      "    <header data-region=\"title-bar\"></header>",
      "    <div data-region=\"activity-bar\"></div>",
      "    <aside data-region=\"sidebar\"></aside>",
      "    <div data-role=\"resize-handle\" data-target=\"sidebar\"></div>",
      "    <main data-region=\"content\">",
      "      <div data-region=\"tab-bar\"></div>",
      "      <section data-region=\"editor\"></section>",
      "      <section data-region=\"panel\"></section>",
      "    </main>",
      "    <div data-role=\"resize-handle\" data-target=\"assistant\"></div>",
      "    <aside data-region=\"assistant-sidebar\"></aside>",
      "    <footer data-region=\"status-bar\"></footer>",
      "  </div>",
      "  <script id=\"bds-shell-bootstrap\" type=\"application/json\">#{Jason.encode!(bootstrap)}</script>",
      "  <script src=\"./app.js\"></script>",
      "</body>",
      "</html>"
    ]
    |> Enum.join("\n")
  end
end