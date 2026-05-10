defmodule BDS.UI.Registry do
  @moduledoc false

  use Gettext, backend: BDS.Gettext

  @spec default_sidebar_view() :: atom()
  def default_sidebar_view, do: :posts

  @spec sidebar_views() :: [map()]
  def sidebar_views do
    [
      %{
        id: :posts,
        label: dgettext("ui", "Posts"),
        activity_group: :top,
        editor_route: :post,
        entity_tab: true,
        demo_kind: :entity
      },
      %{
        id: :pages,
        label: dgettext("ui", "Pages"),
        activity_group: :top,
        editor_route: :post,
        entity_tab: true,
        demo_kind: :entity
      },
      %{
        id: :media,
        label: dgettext("ui", "Media"),
        activity_group: :top,
        editor_route: :media,
        entity_tab: true,
        demo_kind: :entity
      },
      %{
        id: :scripts,
        label: dgettext("ui", "Scripts"),
        activity_group: :top,
        editor_route: :scripts,
        entity_tab: true,
        demo_kind: :entity
      },
      %{
        id: :templates,
        label: dgettext("ui", "Templates"),
        activity_group: :top,
        editor_route: :templates,
        entity_tab: true,
        demo_kind: :entity
      },
      %{
        id: :tags,
        label: dgettext("ui", "Tags"),
        activity_group: :top,
        editor_route: :tags,
        singleton: true,
        demo_kind: :singleton
      },
      %{
        id: :chat,
        label: dgettext("ui", "AI Assistant"),
        activity_group: :top,
        editor_route: :chat,
        entity_tab: true,
        demo_kind: :entity
      },
      %{
        id: :import,
        label: dgettext("ui", "Import"),
        activity_group: :top,
        editor_route: :import,
        entity_tab: true,
        demo_kind: :entity
      },
      %{
        id: :git,
        label: dgettext("ui", "Source Control"),
        activity_group: :bottom,
        editor_route: :git_diff,
        entity_tab: true,
        demo_kind: :entity
      },
      %{
        id: :settings,
        label: dgettext("ui", "Settings"),
        activity_group: :bottom,
        editor_route: :settings,
        singleton: true,
        demo_kind: :singleton
      }
    ]
  end

  @spec editor_routes() :: [map()]
  def editor_routes do
    [
      %{id: :dashboard, singleton: true, entity_tab: false, title: dgettext("ui", "Dashboard")},
      %{id: :post, singleton: false, entity_tab: true, title: dgettext("ui", "Post")},
      %{id: :media, singleton: false, entity_tab: true, title: dgettext("ui", "Media")},
      %{id: :settings, singleton: true, entity_tab: false, title: dgettext("ui", "Settings")},
      %{id: :style, singleton: true, entity_tab: false, title: dgettext("ui", "Style")},
      %{id: :tags, singleton: true, entity_tab: false, title: dgettext("ui", "Tags")},
      %{id: :chat, singleton: false, entity_tab: true, title: dgettext("ui", "Chat")},
      %{id: :import, singleton: false, entity_tab: true, title: dgettext("ui", "Import")},
      %{id: :menu_editor, singleton: true, entity_tab: false, title: dgettext("ui", "Menu")},
      %{
        id: :metadata_diff,
        singleton: true,
        entity_tab: false,
        title: dgettext("ui", "Metadata Diff")
      },
      %{id: :git_diff, singleton: false, entity_tab: true, title: dgettext("ui", "Git Diff")},
      %{
        id: :documentation,
        singleton: true,
        entity_tab: false,
        title: dgettext("ui", "Documentation")
      },
      %{id: :api_documentation, singleton: true, entity_tab: false, title: dgettext("ui", "API")},
      %{
        id: :site_validation,
        singleton: true,
        entity_tab: false,
        title: dgettext("ui", "Site Validation")
      },
      %{
        id: :translation_validation,
        singleton: true,
        entity_tab: false,
        title: dgettext("ui", "Translations")
      },
      %{id: :scripts, singleton: false, entity_tab: true, title: dgettext("ui", "Script")},
      %{id: :templates, singleton: false, entity_tab: true, title: dgettext("ui", "Template")},
      %{
        id: :find_duplicates,
        singleton: true,
        entity_tab: false,
        title: dgettext("ui", "Find Duplicates")
      }
    ]
  end

  @spec sidebar_view(atom()) :: map() | nil
  def sidebar_view(id) when is_atom(id), do: Enum.find(sidebar_views(), &(&1.id == id))
  @spec editor_route(atom()) :: map() | nil
  def editor_route(id) when is_atom(id), do: Enum.find(editor_routes(), &(&1.id == id))
end
