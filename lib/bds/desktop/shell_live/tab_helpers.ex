defmodule BDS.Desktop.ShellLive.TabHelpers do
  @moduledoc false

  alias BDS.Desktop.ShellData
  alias BDS.{BoundedAtoms, Media, Posts}
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Posts.Post
  alias BDS.UI.Registry

  def tab_title(nil, _tab_meta), do: translated("Dashboard")

  def tab_title(tab, tab_meta) do
    case Map.get(tab_meta, {tab.type, tab.id}) do
      %{title: title} when is_binary(title) and title != "" -> title
      _other -> default_tab_title(tab)
    end
  end

  def tab_subtitle(nil, _tab_meta), do: translated("dashboard.subtitle")

  def tab_subtitle(tab, tab_meta) do
    case Map.get(tab_meta, {tab.type, tab.id}) do
      %{subtitle: subtitle} when is_binary(subtitle) and subtitle != "" -> subtitle
      _other -> "Desktop workbench content routed through the Elixir shell."
    end
  end

  def default_tab_title(%{type: type, id: id}) do
    case Registry.editor_route(type) do
      %{singleton: true} -> ShellData.route_label(type)
      _other -> id
    end
  end

  def tab_route_label(nil), do: translated("Dashboard")
  def tab_route_label(%{type: type}), do: ShellData.route_label(type)

  def tab_icon_id(nil), do: "posts"
  def tab_icon_id(%{type: :post}), do: "posts"
  def tab_icon_id(%{type: :git_diff}), do: "git"
  def tab_icon_id(%{type: :style}), do: "settings"
  def tab_icon_id(%{type: type}), do: Atom.to_string(type)

  def sidebar_route_atom(route) when is_atom(route), do: route

  def sidebar_route_atom(route) when is_binary(route),
    do: BoundedAtoms.editor_route(route, :dashboard)

  def tab_id_for_route(route, id) do
    case Registry.editor_route(route) do
      %{singleton: true} -> Atom.to_string(route)
      _other -> id
    end
  end

  def tab_intent(route, requested_intent) do
    case Registry.editor_route(route) do
      %{singleton: true} -> :pin
      _other -> requested_intent
    end
  end

  def post_title(post_id) do
    case Posts.get_post(post_id) do
      %Post{} = post -> post.title || post.slug || post.id
      _other -> "Post"
    end
  end

  def post_subtitle(post_id) do
    case Posts.get_post(post_id) do
      %Post{} = post -> post.slug || "draft"
      _other -> "draft"
    end
  end

  def media_title(media_id) do
    case Media.get_media(media_id) do
      %MediaRecord{} = media -> media.title || media.filename || media.id
      _other -> "Media"
    end
  end

  def media_subtitle(media_id) do
    case Media.get_media(media_id) do
      %MediaRecord{} = media -> media.filename || media.mime_type || "media"
      _other -> "media"
    end
  end

  def parse_integer(value) when is_integer(value), do: value

  def parse_integer(value) do
    case Integer.parse(to_string(value || "0")) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp translated(text), do: ShellData.translate(text, %{}, BDS.Desktop.UILocale.current())
end
