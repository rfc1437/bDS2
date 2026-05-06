defmodule BDS.UI.Workbench do
  @moduledoc false

  use Gettext, backend: BDS.Gettext

  alias BDS.UI.Registry

  @singleton_tabs MapSet.new([
                    :settings,
                    :tags,
                    :style,
                    :scripts,
                    :menu_editor,
                    :documentation,
                    :api_documentation,
                    :metadata_diff,
                    :site_validation,
                    :translation_validation,
                    :find_duplicates
                  ])

  defstruct sidebar_visible: true,
            sidebar_width: 280,
            active_view: :posts,
            assistant_sidebar_visible: false,
            assistant_sidebar_width: 360,
            panel: %{visible: false, active_tab: :tasks},
            tabs: [],
            active_tab: nil,
            editor_route: :dashboard,
            dirty_tabs: MapSet.new()

  def new(opts \\ []) do
    %__MODULE__{
      sidebar_visible: Keyword.get(opts, :sidebar_visible, true),
      sidebar_width: clamp_sidebar_width(Keyword.get(opts, :sidebar_width, 280)),
      active_view: normalize_type(Keyword.get(opts, :active_view, :posts)),
      assistant_sidebar_visible: Keyword.get(opts, :assistant_sidebar_visible, false),
      assistant_sidebar_width:
        clamp_assistant_sidebar_width(Keyword.get(opts, :assistant_sidebar_width, 360)),
      panel: %{
        visible: Keyword.get(opts, :panel_visible, false),
        active_tab: Keyword.get(opts, :panel_tab, :tasks)
      },
      dirty_tabs: MapSet.new(Keyword.get(opts, :dirty_tabs, []))
    }
    |> sync_editor_route()
    |> normalize_panel()
  end

  def set_sidebar_width(state, width) when is_integer(width) do
    %{state | sidebar_width: clamp_sidebar_width(width)}
  end

  def set_assistant_sidebar_width(state, width) when is_integer(width) do
    %{state | assistant_sidebar_width: clamp_assistant_sidebar_width(width)}
  end

  def open_tab(state, type, id, intent) do
    {tabs, opened_tab} = upsert_tab(state.tabs, normalize_type(type), id, intent)

    state
    |> Map.put(:tabs, tabs)
    |> Map.put(:active_tab, tab_ref(opened_tab))
    |> sync_editor_route()
    |> normalize_panel()
  end

  def open_tab_in_background(state, type, id, intent) do
    current_active = state.active_tab
    {tabs, _opened_tab} = upsert_tab(state.tabs, normalize_type(type), id, intent)

    state
    |> Map.put(:tabs, tabs)
    |> Map.put(:active_tab, current_active)
    |> sync_editor_route()
    |> normalize_panel()
  end

  def close_tab(state, type, id) do
    type = normalize_type(type)
    target = {type, id}
    index = Enum.find_index(state.tabs, &(tab_ref(&1) == target))

    if is_nil(index) do
      state
    else
      tabs = List.delete_at(state.tabs, index)

      next_active =
        cond do
          state.active_tab != target -> state.active_tab
          tabs == [] -> nil
          index < length(tabs) -> tab_ref(Enum.at(tabs, index))
          true -> tab_ref(List.last(tabs))
        end

      state
      |> Map.put(:tabs, tabs)
      |> Map.put(:active_tab, next_active)
      |> sync_editor_route()
      |> normalize_panel()
    end
  end

  def pin_tab(state, type, id) do
    type = normalize_type(type)

    tabs =
      Enum.map(state.tabs, fn tab ->
        if tab_ref(tab) == {type, id}, do: %{tab | is_transient: false}, else: tab
      end)

    %{state | tabs: tabs}
  end

  def clear_tabs(state) do
    %{state | tabs: [], active_tab: nil, editor_route: :dashboard, dirty_tabs: MapSet.new()}
    |> normalize_panel()
  end

  def mark_dirty(state, type, id) do
    if normalize_type(type) == :post do
      %{state | dirty_tabs: MapSet.put(state.dirty_tabs, {normalize_type(type), id})}
    else
      state
    end
  end

  def clear_dirty(state, type, id) do
    %{state | dirty_tabs: MapSet.delete(state.dirty_tabs, {normalize_type(type), id})}
  end

  def dirty?(state, type, id) do
    MapSet.member?(state.dirty_tabs, {normalize_type(type), id})
  end

  def toggle_sidebar(state), do: %{state | sidebar_visible: not state.sidebar_visible}

  def set_panel_visible(state, visible) when is_boolean(visible) do
    %{state | panel: %{state.panel | visible: visible}}
  end

  def toggle_panel(state) do
    set_panel_visible(state, not state.panel.visible)
  end

  def toggle_assistant_sidebar(state) do
    %{state | assistant_sidebar_visible: not state.assistant_sidebar_visible}
  end

  def set_panel_tab(state, tab) when tab in [:tasks, :output, :post_links, :git_log] do
    %{state | panel: %{state.panel | active_tab: tab}}
  end

  def click_activity(state, activity_id) do
    activity_id = normalize_type(activity_id)

    cond do
      state.active_view == activity_id -> toggle_sidebar(state)
      state.sidebar_visible -> %{state | active_view: activity_id}
      true -> %{state | active_view: activity_id, sidebar_visible: true}
    end
  end

  def activity_buttons(state, git_badge_count \\ 0) do
    Registry.sidebar_views()
    |> Enum.map(fn view ->
      %{
        id: view.id,
        label: view.label,
        activity_group: view.activity_group,
        active: state.sidebar_visible and state.active_view == view.id,
        badge: activity_badge(view.id, git_badge_count)
      }
    end)
  end

  def status_bar(state, opts) do
    post_count = Keyword.get(opts, :post_count, 0)
    media_count = Keyword.get(opts, :media_count, 0)

    %{
      left: %{
        running_task_message: Keyword.get(opts, :running_task_message),
        running_task_overflow: Keyword.get(opts, :running_task_overflow)
      },
      right: %{
        post_status: post_status(state, Keyword.get(opts, :active_post_status)),
        post_count: "#{post_count} #{dngettext("ui", "post", "posts", post_count)}",
        post_count_value: post_count,
        media_count: "#{media_count} #{dngettext("ui", "media", "media", media_count)}",
        media_count_value: media_count,
        token_usage: token_usage(state, Keyword.get(opts, :token_usage)),
        theme_badge: Keyword.get(opts, :theme_badge, "default"),
        offline_mode: Keyword.get(opts, :offline_mode, false),
        ui_language: Keyword.get(opts, :ui_language, "en"),
        brand: "bDS"
      }
    }
  end

  defp upsert_tab(tabs, type, id, intent) do
    transient? = transient_tab?(type, intent)

    case Enum.find_index(tabs, &(tab_ref(&1) == {type, id})) do
      nil ->
        new_tab = %{type: type, id: id, is_transient: transient?}

        tabs =
          cond do
            transient? -> replace_transient_tab(tabs, type, new_tab)
            true -> tabs ++ [new_tab]
          end

        {tabs, new_tab}

      index ->
        existing = Enum.at(tabs, index)
        updated = if intent == :pin, do: %{existing | is_transient: false}, else: existing
        {List.replace_at(tabs, index, updated), updated}
    end
  end

  defp replace_transient_tab(tabs, type, new_tab) do
    case Enum.find_index(tabs, &(&1.type == type and &1.is_transient)) do
      nil -> tabs ++ [new_tab]
      index -> List.replace_at(tabs, index, new_tab)
    end
  end

  defp transient_tab?(type, _intent) when type in [:chat, :import], do: false

  defp transient_tab?(type, intent) do
    if MapSet.member?(@singleton_tabs, type), do: false, else: transient_from_intent(intent)
  end

  defp transient_from_intent(:preview), do: true
  defp transient_from_intent(_intent), do: false

  defp sync_editor_route(%{active_tab: nil} = state), do: %{state | editor_route: :dashboard}
  defp sync_editor_route(%{active_tab: {type, _id}} = state), do: %{state | editor_route: type}

  defp normalize_panel(state) do
    if panel_tab_available?(state.editor_route, state.panel.active_tab) do
      state
    else
      %{state | panel: %{state.panel | active_tab: :tasks}}
    end
  end

  defp panel_tab_available?(_route, tab) when tab in [:tasks, :output], do: true
  defp panel_tab_available?(:post, :post_links), do: true
  defp panel_tab_available?(route, :git_log) when route in [:post, :media], do: true
  defp panel_tab_available?(_route, _tab), do: false

  defp activity_badge(:git, count) when is_integer(count) and count > 0 do
    %{count: count, display: if(count > 99, do: "99+", else: Integer.to_string(count))}
  end

  defp activity_badge(_id, _count), do: nil

  defp post_status(%{editor_route: :post}, status) when not is_nil(status), do: to_string(status)
  defp post_status(_state, _status), do: nil

  defp token_usage(%{editor_route: :chat}, usage), do: usage
  defp token_usage(_state, _usage), do: nil

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(type) when is_binary(type), do: String.to_existing_atom(type)

  defp tab_ref(tab), do: {tab.type, tab.id}

  defp clamp_sidebar_width(width), do: max(200, min(width, 500))
  defp clamp_assistant_sidebar_width(width), do: max(280, min(width, 640))
end
