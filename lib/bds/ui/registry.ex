defmodule BDS.UI.Registry do
  @moduledoc false

  @sidebar_views [
    %{
      id: :posts,
      label: "Posts",
      activity_group: :top,
      editor_route: :post,
      entity_tab: true,
      demo_kind: :entity
    },
    %{
      id: :pages,
      label: "Pages",
      activity_group: :top,
      editor_route: :post,
      entity_tab: true,
      demo_kind: :entity
    },
    %{
      id: :media,
      label: "Media",
      activity_group: :top,
      editor_route: :media,
      entity_tab: true,
      demo_kind: :entity
    },
    %{
      id: :scripts,
      label: "Scripts",
      activity_group: :top,
      editor_route: :scripts,
      entity_tab: true,
      demo_kind: :entity
    },
    %{
      id: :templates,
      label: "Templates",
      activity_group: :top,
      editor_route: :templates,
      entity_tab: true,
      demo_kind: :entity
    },
    %{
      id: :tags,
      label: "Tags",
      activity_group: :top,
      editor_route: :tags,
      singleton: true,
      demo_kind: :singleton
    },
    %{
      id: :chat,
      label: "AI Assistant",
      activity_group: :top,
      editor_route: :chat,
      entity_tab: true,
      demo_kind: :entity
    },
    %{
      id: :import,
      label: "Import",
      activity_group: :top,
      editor_route: :import,
      entity_tab: true,
      demo_kind: :entity
    },
    %{
      id: :git,
      label: "Source Control",
      activity_group: :bottom,
      editor_route: :git_diff,
      entity_tab: true,
      demo_kind: :entity
    },
    %{
      id: :settings,
      label: "Settings",
      activity_group: :bottom,
      editor_route: :settings,
      singleton: true,
      demo_kind: :singleton
    }
  ]

  @editor_routes [
    %{id: :dashboard, singleton: true, entity_tab: false, title: "Dashboard"},
    %{id: :post, singleton: false, entity_tab: true, title: "Post"},
    %{id: :media, singleton: false, entity_tab: true, title: "Media"},
    %{id: :settings, singleton: true, entity_tab: false, title: "Settings"},
    %{id: :style, singleton: true, entity_tab: false, title: "Style"},
    %{id: :tags, singleton: true, entity_tab: false, title: "Tags"},
    %{id: :chat, singleton: false, entity_tab: true, title: "Chat"},
    %{id: :import, singleton: false, entity_tab: true, title: "Import"},
    %{id: :menu_editor, singleton: true, entity_tab: false, title: "Menu"},
    %{id: :metadata_diff, singleton: true, entity_tab: false, title: "Metadata Diff"},
    %{id: :git_diff, singleton: false, entity_tab: true, title: "Git Diff"},
    %{id: :documentation, singleton: true, entity_tab: false, title: "Documentation"},
    %{id: :api_documentation, singleton: true, entity_tab: false, title: "API"},
    %{id: :site_validation, singleton: true, entity_tab: false, title: "Site Validation"},
    %{id: :translation_validation, singleton: true, entity_tab: false, title: "Translations"},
    %{id: :scripts, singleton: false, entity_tab: true, title: "Script"},
    %{id: :templates, singleton: false, entity_tab: true, title: "Template"},
    %{id: :find_duplicates, singleton: true, entity_tab: false, title: "Find Duplicates"}
  ]

  def default_sidebar_view, do: :posts
  def sidebar_views, do: @sidebar_views
  def editor_routes, do: @editor_routes

  def sidebar_view(id) when is_atom(id), do: Enum.find(@sidebar_views, &(&1.id == id))
  def editor_route(id) when is_atom(id), do: Enum.find(@editor_routes, &(&1.id == id))
end
