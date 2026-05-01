defmodule BDS.BoundedAtoms do
  @moduledoc false

  alias BDS.UI.Registry

  @panel_tabs [:tasks, :output, :post_links, :git_log]
  @post_statuses [:draft, :published, :archived]
  @translation_statuses [:draft, :published]
  @script_kinds [:macro, :utility, :transform]
  @template_kinds [:post, :list, :not_found, :partial]
  @menu_kinds [:page, :submenu, :category_archive, :home]
  @import_sections [
    :post_conflicts,
    :page_conflicts,
    :posts,
    :other,
    :pages,
    :media,
    :taxonomy,
    :macros
  ]
  @taxonomy_types [:categories, :tags]
  @ai_endpoints [:online, :airplane]
  @mcp_agents [
    :claude_code,
    :claude_desktop,
    :github_copilot,
    :gemini_cli,
    :opencode,
    :mistral_vibe,
    :openai_codex
  ]
  @shell_commands [
    :toggle_sidebar,
    :toggle_panel,
    :toggle_assistant_sidebar,
    :view_posts,
    :view_media,
    :edit_preferences,
    :edit_menu,
    :documentation,
    :api_documentation,
    :close_tab
  ]

  def atom(value, allowed, fallback \\ nil)

  def atom(value, allowed, fallback) when is_atom(value) do
    if value in allowed, do: value, else: fallback
  end

  def atom(value, allowed, fallback) when is_binary(value),
    do: string_atom(value, allowed, fallback)

  def atom(_value, _allowed, fallback), do: fallback

  def sidebar_view(value, fallback \\ nil), do: atom(value, sidebar_views(), fallback)
  def editor_route(value, fallback \\ nil), do: atom(value, editor_routes(), fallback)
  def panel_tab(value, fallback \\ nil), do: atom(value, @panel_tabs, fallback)
  def post_status(value, fallback \\ nil), do: atom(value, @post_statuses, fallback)
  def translation_status(value, fallback \\ nil), do: atom(value, @translation_statuses, fallback)
  def script_kind(value, fallback \\ nil), do: atom(value, @script_kinds, fallback)
  def template_kind(value, fallback \\ nil), do: atom(value, @template_kinds, fallback)

  def menu_kind(value, fallback \\ nil),
    do: atom(normalize_menu_kind(value), @menu_kinds, fallback)

  def import_section(value, fallback \\ nil), do: atom(value, @import_sections, fallback)
  def taxonomy_type(value, fallback \\ nil), do: atom(value, @taxonomy_types, fallback)
  def ai_endpoint(value, fallback \\ nil), do: atom(value, @ai_endpoints, fallback)
  def mcp_agent(value, fallback \\ nil), do: atom(value, @mcp_agents, fallback)
  def shell_command(value, fallback \\ nil), do: atom(value, @shell_commands, fallback)

  defp string_atom(value, allowed, fallback) do
    Enum.find(allowed, fallback, &(Atom.to_string(&1) == value))
  end

  defp sidebar_views do
    Enum.map(Registry.sidebar_views(), & &1.id)
  end

  defp editor_routes do
    Enum.map(Registry.editor_routes(), & &1.id)
  end

  defp normalize_menu_kind("category-archive"), do: "category_archive"
  defp normalize_menu_kind(value), do: value
end
