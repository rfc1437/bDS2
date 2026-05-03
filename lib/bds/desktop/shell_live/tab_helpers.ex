defmodule BDS.Desktop.ShellLive.TabHelpers do
  @moduledoc false

  alias BDS.Desktop.ShellData
  alias BDS.{AI, BoundedAtoms, ImportDefinitions, Media, Posts, Scripts, Templates}
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Posts.Post
  alias BDS.UI.Registry
  use Gettext, backend: BDS.Gettext

  def tab_title(nil, _tab_meta), do: dgettext("ui", "Dashboard")

  def tab_title(tab, tab_meta) do
    case Map.get(tab_meta, {tab.type, tab.id}) do
      %{title: title} when is_binary(title) and title != "" -> title
      _other -> default_tab_title(tab)
    end
  end

  def tab_subtitle(nil, _tab_meta), do: dgettext("ui", "Overview of your blog database")

  def tab_subtitle(tab, tab_meta) do
    case Map.get(tab_meta, {tab.type, tab.id}) do
      %{subtitle: subtitle} when is_binary(subtitle) and subtitle != "" -> subtitle
      _other -> default_tab_subtitle(tab)
    end
  end

  def sync_tab_meta(%{tabs: tabs}, tab_meta) when is_list(tabs) and is_map(tab_meta) do
    Enum.reduce(tabs, %{}, fn tab, acc ->
      key = {tab.type, tab.id}
      existing_meta = Map.get(tab_meta, key, %{})
      synced_meta = merge_missing_meta(existing_meta, derived_tab_meta(tab))

      if map_size(synced_meta) == 0 do
        acc
      else
        Map.put(acc, key, synced_meta)
      end
    end)
  end

  def sync_tab_meta(_workbench, tab_meta) when is_map(tab_meta), do: tab_meta

  def default_tab_title(%{type: type, id: id}) do
    case Registry.editor_route(type) do
      %{singleton: true} -> ShellData.route_label(type)
      _other -> id
    end
  end

  defp default_tab_subtitle(_tab), do: "Desktop workbench content routed through the Elixir shell."

  def tab_route_label(nil), do: dgettext("ui", "Dashboard")
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
      %Post{} = post -> post_record_title(post)
      _other -> "Post"
    end
  end

  def post_subtitle(post_id) do
    case Posts.get_post(post_id) do
      %Post{} = post -> post_record_subtitle(post)
      _other -> "draft"
    end
  end

  def media_title(media_id) do
    case Media.get_media(media_id) do
      %MediaRecord{} = media -> media_record_title(media)
      _other -> "Media"
    end
  end

  def media_subtitle(media_id) do
    case Media.get_media(media_id) do
      %MediaRecord{} = media -> media_record_subtitle(media)
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

  defp derived_tab_meta(%{type: :post, id: post_id}) do
    case Posts.get_post(post_id) do
      %Post{} = post -> %{title: post_record_title(post), subtitle: post_record_subtitle(post)}
      _other -> %{}
    end
  end

  defp derived_tab_meta(%{type: :media, id: media_id}) do
    case Media.get_media(media_id) do
      %MediaRecord{} = media ->
        %{title: media_record_title(media), subtitle: media_record_subtitle(media)}

      _other ->
        %{}
    end
  end

  defp derived_tab_meta(%{type: :scripts, id: script_id}) do
    case Scripts.get_script(script_id) do
      %{title: title, id: id} ->
        %{title: blank_to_nil(title) || id, subtitle: dgettext("ui", "Automation helpers")}

      _other ->
        %{}
    end
  end

  defp derived_tab_meta(%{type: :templates, id: template_id}) do
    case Templates.get_template(template_id) do
      %{title: title, id: id} ->
        %{title: blank_to_nil(title) || id, subtitle: dgettext("ui", "Site rendering")}

      _other ->
        %{}
    end
  end

  defp derived_tab_meta(%{type: :chat, id: conversation_id}) do
    case AI.get_chat_conversation(conversation_id) do
      conversation when is_map(conversation) ->
        %{title: chat_record_title(conversation), subtitle: dgettext("ui", "AI conversations")}

      _other ->
        %{}
    end
  end

  defp derived_tab_meta(%{type: :import, id: definition_id}) do
    case ImportDefinitions.get_definition(definition_id) do
      %{name: name} ->
        %{
          title: blank_to_nil(name) || dgettext("ui", "Untitled Import"),
          subtitle: dgettext("ui", "Select a WordPress export file (WXR) and an uploads folder to analyze what would be imported.")
        }

      _other ->
        %{}
    end
  end

  defp derived_tab_meta(%{type: :git_diff, id: "git-working-tree"}) do
    %{title: dgettext("ui", "Working tree"), subtitle: dgettext("ui", "Working tree and history")}
  end

  defp derived_tab_meta(%{type: :menu_editor}) do
    %{
      title: dgettext("ui", "Blog Menu"),
      subtitle: dgettext("ui", "Manage the central blog navigation outline and save it to meta/menu.opml.")
    }
  end

  defp derived_tab_meta(_tab), do: %{}

  defp merge_missing_meta(existing_meta, fresh_meta) do
    existing_meta
    |> maybe_put_missing(:title, Map.get(fresh_meta, :title))
    |> maybe_put_missing(:subtitle, Map.get(fresh_meta, :subtitle))
  end

  defp maybe_put_missing(meta, key, value) do
    cond do
      blank_to_nil(value) == nil ->
        meta

      existing_value_present?(Map.get(meta, key)) ->
        meta

      true ->
        Map.put(meta, key, value)
    end
  end

  defp existing_value_present?(value) do
    if is_binary(value), do: String.trim(value) != "", else: false
  end

  defp post_record_title(%Post{} = post), do: blank_to_nil(post.title) || blank_to_nil(post.slug) || post.id

  defp post_record_subtitle(%Post{} = post), do: Atom.to_string(post.status)

  defp media_record_title(%MediaRecord{} = media) do
    blank_to_nil(media.title) || blank_to_nil(media.original_name) || media.id
  end

  defp media_record_subtitle(%MediaRecord{} = media) do
    blank_to_nil(media.original_name) || blank_to_nil(media.mime_type) || "media"
  end

  defp chat_record_title(%{title: title, id: id}), do: blank_to_nil(title) || id

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
