defmodule BDS.Desktop.ShellLive.SidebarComponents do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Desktop.ShellData
  alias BDS.Desktop.UILocale
  alias BDS.UI.Registry
  use Gettext, backend: BDS.Gettext

  def sidebar_content(assigns) do
    UILocale.put(assigns.page_language)
    assigns = prepare_filter_assigns(assigns)

    ~H"""
    <%= render_sidebar_filters(assigns) %>
    <%= render_sidebar_body(assigns) %>
    <%= render_sidebar_load_more(assigns) %>
    """
  end

  def filters_enabled?(sidebar_data) do
    sidebar_data
    |> Map.get(:filters)
    |> then(&(is_map(&1) and Map.get(&1, :enabled, false)))
  end

  def filters_visible?(sidebar_data) do
    sidebar_data
    |> Map.get(:filters, %{})
    |> Map.get(:filter_panel_visible, false)
  end

  defp prepare_filter_assigns(assigns) do
    filters = Map.get(assigns.sidebar_data, :filters)

    if is_map(filters) and Map.get(filters, :enabled) do
      selected = Map.get(filters, :selected, %{})

      assigns
      |> assign(:sidebar_filters_config, filters)
      |> assign(:selected_filters, selected)
      |> assign(:filter_panel_visible, Map.get(filters, :filter_panel_visible, false))
      |> assign(:archive_collapsed, Map.get(filters, :archive_collapsed, true))
      |> assign(:tags_collapsed, Map.get(filters, :tags_collapsed, true))
      |> assign(:categories_collapsed, Map.get(filters, :categories_collapsed, true))
      |> assign(:expanded_year, Map.get(filters, :expanded_year))
      |> assign(:year_groups, group_year_month_counts(Map.get(filters, :year_month_counts, [])))
    else
      assigns
    end
  end

  defp render_sidebar_filters(assigns) do
    filters = Map.get(assigns.sidebar_data, :filters)

    if is_map(filters) and Map.get(filters, :enabled) do
      ~H"""
      <form class="search-box" data-testid="sidebar-search-form" phx-change="update_sidebar_search" phx-submit="update_sidebar_search">
        <input
          type="text"
          name="sidebar_filters[search]"
          value={Map.get(@selected_filters, :search) || ""}
          placeholder={@sidebar_filters_config.search_placeholder}
        />
        <button type="submit" title={dgettext("ui", "Search")}>
          <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
            <path d="M15.7 14.3l-4.2-4.2c-.2-.2-.5-.3-.8-.3.9-1.1 1.5-2.5 1.5-4C12.2 2.6 9.6 0 6.4 0S.6 2.6.6 5.8s2.6 5.8 5.8 5.8c1.5 0 2.9-.5 4-1.4 0 .3.1.6.3.8l4.2 4.2c.2.2.5.3.7.3s.5-.1.7-.3c.4-.4.4-1 0-1.4zm-9.3-4c-2.5 0-4.5-2-4.5-4.5s2-4.5 4.5-4.5 4.5 2 4.5 4.5-2 4.5-4.5 4.5z"/>
          </svg>
        </button>
        <%= if Map.get(@selected_filters, :search) do %>
          <button class="clear-search" data-testid="sidebar-clear-search" type="button" phx-click="clear_sidebar_search">×</button>
        <% end %>
      </form>

      <%= if Map.get(@sidebar_filters_config, :has_active_filters) do %>
        <div class="filter-status">
          <span>
            <%= @sidebar_filters_config.results_label %>: <%= @sidebar_filters_config.loaded_count %>/<%= @sidebar_filters_config.total_count %>
          </span>
          <button data-testid="sidebar-clear-filters" type="button" phx-click="clear_sidebar_filters">
            <%= @sidebar_filters_config.clear_filters_label %>
          </button>
        </div>
      <% end %>

      <%= if @filter_panel_visible do %>
        <%= if Enum.any?(@year_groups) do %>
          <div class="calendar-view">
            <div
              class={[
                "calendar-header",
                "collapsible-header",
                if(@archive_collapsed, do: "collapsed", else: "expanded")
              ]}
              data-testid="sidebar-filter-archive-header"
              phx-click="toggle_sidebar_archive"
            >
              <span class="collapse-icon"><%= if @archive_collapsed, do: "▶", else: "▼" %></span>
              <span><%= @sidebar_filters_config.archive_label %></span>
              <%= if Map.get(@selected_filters, :year) do %>
                <button class="clear-filter" type="button" phx-click="clear_sidebar_month" phx-stop-propagation>✕</button>
              <% end %>
            </div>
            <%= unless @archive_collapsed do %>
              <div class="calendar-years">
                <%= for year_group <- @year_groups do %>
                  <div class="calendar-year">
                    <div
                      class={[
                        "calendar-year-header",
                        if(Map.get(@selected_filters, :year) == year_group.year and is_nil(Map.get(@selected_filters, :month)), do: "selected")
                      ]}
                      phx-click="select_sidebar_year"
                      phx-value-year={year_group.year}
                    >
                      <span class="expand-icon"><%= if @expanded_year == year_group.year, do: "▼", else: "▶" %></span>
                      <span class="year-label"><%= year_group.year %></span>
                      <span class="year-count"><%= year_group.count %></span>
                    </div>
                    <%= if @expanded_year == year_group.year do %>
                      <div class="calendar-months">
                        <%= for month_entry <- year_group.months do %>
                          <button
                            class={[
                              "calendar-month",
                              if(Map.get(@selected_filters, :year) == year_group.year and Map.get(@selected_filters, :month) == month_entry.month, do: "selected")
                            ]}
                            data-testid="sidebar-filter-month"
                            type="button"
                            phx-click="select_sidebar_month"
                            phx-value-year={year_group.year}
                            phx-value-month={month_entry.month}
                          >
                            <span class="month-label"><%= ShellData.format_dashboard_month(year_group.year, month_entry.month) %></span>
                            <span class="month-count"><%= month_entry.count %></span>
                          </button>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <div class="filter-panel">
          <%= if Enum.any?(Map.get(@sidebar_filters_config, :available_tags, [])) do %>
            <section class="filter-section">
              <div
                class={[
                  "filter-header",
                  "collapsible-header",
                  if(@tags_collapsed, do: "collapsed", else: "expanded")
                ]}
                data-testid="sidebar-filter-tags-header"
                phx-click="toggle_sidebar_tags"
              >
                <span class="collapse-icon"><%= if @tags_collapsed, do: "▶", else: "▼" %></span>
                <span><%= @sidebar_filters_config.tags_label %></span>
                <%= if Enum.any?(Map.get(@selected_filters, :tags, [])) do %>
                  <button class="clear-filter" type="button" phx-click="clear_sidebar_tags" phx-stop-propagation title={@sidebar_filters_config.clear_tags_label}>✕</button>
                <% end %>
              </div>
              <%= unless @tags_collapsed do %>
                <div class="filter-chips">
                  <%= for tag <- Map.get(@sidebar_filters_config, :available_tags, []) do %>
                    <button
                      class={[
                        "filter-chip",
                        if(tag in Map.get(@selected_filters, :tags, []), do: "active"),
                        if(sidebar_filter_tag_color(@sidebar_filters_config, tag), do: "has-color")
                      ]}
                      style={sidebar_filter_chip_style(@sidebar_filters_config, tag)}
                      data-testid="sidebar-filter-tag"
                      data-filter-tag={tag}
                      type="button"
                      phx-click="toggle_sidebar_tag"
                      phx-value-tag={tag}
                    >
                      <%= tag %>
                    </button>
                  <% end %>
                </div>
              <% end %>
            </section>
          <% end %>

          <%= if Enum.any?(Map.get(@sidebar_filters_config, :available_categories, [])) do %>
            <section class="filter-section">
              <div
                class={[
                  "filter-header",
                  "collapsible-header",
                  if(@categories_collapsed, do: "collapsed", else: "expanded")
                ]}
                data-testid="sidebar-filter-categories-header"
                phx-click="toggle_sidebar_categories"
              >
                <span class="collapse-icon"><%= if @categories_collapsed, do: "▶", else: "▼" %></span>
                <span><%= @sidebar_filters_config.categories_label %></span>
                <%= if Enum.any?(Map.get(@selected_filters, :categories, [])) do %>
                  <button class="clear-filter" type="button" phx-click="clear_sidebar_categories" phx-stop-propagation title={@sidebar_filters_config.clear_categories_label}>✕</button>
                <% end %>
              </div>
              <%= unless @categories_collapsed do %>
                <div class="filter-chips">
                  <%= for category <- Map.get(@sidebar_filters_config, :available_categories, []) do %>
                    <button
                      class={[
                        "filter-chip",
                        if(category in Map.get(@selected_filters, :categories, []), do: "active")
                      ]}
                      data-testid="sidebar-filter-category"
                      data-filter-category={category}
                      type="button"
                      phx-click="toggle_sidebar_category"
                      phx-value-category={category}
                    >
                      <%= category %>
                    </button>
                  <% end %>
                </div>
              <% end %>
            </section>
          <% end %>
        </div>
      <% end %>
      """
    else
      ~H"""
      """
    end
  end

  defp render_sidebar_load_more(assigns) do
    filters = Map.get(assigns.sidebar_data, :filters, %{})

    if Map.get(filters, :has_more) do
      ~H"""
      <div class="sidebar-load-more">
        <button class="load-more-button" data-testid="sidebar-load-more" type="button" phx-click="load_more_sidebar">
          <%= dgettext("ui", "Load more") %>
        </button>
      </div>
      """
    else
      ~H"""
      """
    end
  end

  defp render_sidebar_body(assigns) do
    case assigns.sidebar_data.layout do
      "post_list" -> render_post_sidebar(assigns)
      "media_grid" -> render_media_sidebar(assigns)
      "entity_list" -> render_entity_sidebar(assigns)
      "nav_list" -> render_nav_sidebar(assigns)
      _other -> render_default_sidebar(assigns)
    end
  end

  defp render_post_sidebar(assigns) do
    ~H"""
    <%= for section <- Map.get(@sidebar_data, :sections, []) do %>
      <section class="sidebar-section">
        <div class="sidebar-section-title">
          <span class={"section-icon status-#{Map.get(section, :status, "draft")}"}>●</span>
          <span data-testid="sidebar-section-title"><%= section.title %></span>
          <span class="sidebar-section-count"><%= Map.get(section, :count, length(Map.get(section, :items, []))) %></span>
        </div>
        <div class="sidebar-list">
          <%= for item <- Map.get(section, :items, []) do %>
            <div class="sidebar-item-row" data-item-id={item.id}>
              <button
                class={["sidebar-item", "sidebar-post-item", "post-type-post", if(sidebar_item_selected?(@workbench, item.route, item.id), do: "selected")]}
                data-testid="sidebar-open-item"
                data-route={item.route}
                data-item-id={item.id}
                data-open-title={item.title}
                data-open-subtitle={format_sidebar_timestamp(item.meta_timestamp)}
                type="button"
                phx-click="open_sidebar_item"
                phx-value-route={item.route}
                phx-value-id={item.id}
                phx-value-title={item.title}
                phx-value-subtitle={format_sidebar_timestamp(item.meta_timestamp)}
              >
                <span class="post-type-icon" title="post">●</span>
                <span class="sidebar-item-content">
                  <span class="sidebar-item-title-row">
                    <span class="sidebar-item-title"><%= item.title %></span>
                  </span>
                  <span class="sidebar-item-meta"><%= format_sidebar_timestamp(item.meta_timestamp) %></span>
                </span>
              </button>
              <%= if sidebar_deletable?(item.route) do %>
                <button
                  class="sidebar-delete-button"
                  data-testid={sidebar_delete_testid(item.route)}
                  data-item-id={item.id}
                  type="button"
                  title={sidebar_delete_title(item.route)}
                  phx-click="confirm_sidebar_delete"
                  phx-value-route={item.route}
                  phx-value-id={item.id}
                  phx-value-title={item.title}
                >
                  ×
                </button>
              <% end %>
            </div>
          <% end %>
        </div>
      </section>
    <% end %>
    <%= if Enum.empty?(Map.get(@sidebar_data, :sections, [])) do %>
      <div class="sidebar-empty">
        <p><%= Map.get(@sidebar_data, :empty_message, dgettext("ui", "No items")) %></p>
      </div>
    <% end %>
    """
  end

  defp render_media_sidebar(assigns) do
    ~H"""
    <%= if Enum.any?(Map.get(@sidebar_data, :items, [])) do %>
      <div class="sidebar-list media-grid">
        <%= for item <- Map.get(@sidebar_data, :items, []) do %>
          <div class="media-item-row" data-item-id={item.id}>
            <button
              class={["media-item", if(sidebar_item_selected?(@workbench, item.route, item.id), do: "selected")]}
              data-testid="sidebar-open-item"
              data-route={item.route}
              data-item-id={item.id}
              data-open-title={item.title}
              data-open-subtitle={item.meta}
              type="button"
              title={item.title}
              phx-click="open_sidebar_item"
              phx-value-route={item.route}
              phx-value-id={item.id}
              phx-value-title={item.title}
              phx-value-subtitle={item.meta}
            >
              <span class={media_thumbnail_class(item)}>
                <%= if image_media?(item) do %>
                  <span class="media-thumbnail-fallback"><%= media_thumbnail_glyph(item.mime_type) %></span>
                  <img class="media-thumbnail-image" src={"/media-thumbnail/#{item.id}"} alt="" loading="lazy" decoding="async" />
                <% else %>
                  <span class="media-thumbnail-fallback"><%= media_thumbnail_glyph(item.mime_type) %></span>
                <% end %>
              </span>
              <span class="media-item-info">
                <span class="media-item-name"><%= item.title %></span>
                <span class="media-item-size"><%= item.meta %></span>
              </span>
            </button>
            <%= if sidebar_deletable?(item.route) do %>
              <button
                class="sidebar-delete-button"
                data-testid={sidebar_delete_testid(item.route)}
                data-item-id={item.id}
                type="button"
                title={sidebar_delete_title(item.route)}
                phx-click="confirm_sidebar_delete"
                phx-value-route={item.route}
                phx-value-id={item.id}
                phx-value-title={item.title}
              >
                ×
              </button>
            <% end %>
          </div>
        <% end %>
      </div>
    <% else %>
      <div class="sidebar-empty">
        <p><%= Map.get(@sidebar_data, :empty_message, dgettext("ui", "No items")) %></p>
      </div>
    <% end %>
    """
  end

  defp render_entity_sidebar(assigns) do
    ~H"""
    <%= if Enum.any?(Map.get(@sidebar_data, :items, [])) do %>
      <div class={if(template_sidebar?(@sidebar_data), do: "chat-list-items", else: "settings-nav-list")}>
        <%= for item <- Map.get(@sidebar_data, :items, []) do %>
          <%= if sidebar_deletable?(item.route) do %>
            <div
              class={["chat-list-item", if(sidebar_item_selected?(@workbench, item.route, item.id), do: "active")]}
              data-item-id={item.id}
            >
              <button
                class="chat-item-open"
                data-testid="sidebar-open-item"
                data-route={item.route}
                data-item-id={item.id}
                data-open-title={item.title}
                data-open-subtitle={item.meta || ""}
                type="button"
                phx-click="open_sidebar_item"
                phx-value-route={item.route}
                phx-value-id={item.id}
                phx-value-title={item.title}
                phx-value-subtitle={item.meta || ""}
              >
                <span class="chat-item-content">
                  <span class="chat-item-title"><%= item.title %></span>
                  <span class="chat-item-date"><%= item.meta || "" %></span>
                </span>
              </button>
              <button
                class="sidebar-delete-button"
                data-testid={sidebar_delete_testid(item.route)}
                data-item-id={item.id}
                type="button"
                title={sidebar_delete_title(item.route)}
                phx-click="confirm_sidebar_delete"
                phx-value-route={item.route}
                phx-value-id={item.id}
                phx-value-title={item.title}
              >
                ×
              </button>
            </div>
          <% else %>
            <button
              class={["chat-list-item", if(sidebar_item_selected?(@workbench, item.route, item.id), do: "active")]}
              data-testid="sidebar-open-item"
              data-route={item.route}
              data-item-id={item.id}
              data-open-title={item.title}
              data-open-subtitle={item.meta || ""}
              type="button"
              phx-click="open_sidebar_item"
              phx-value-route={item.route}
              phx-value-id={item.id}
              phx-value-title={item.title}
              phx-value-subtitle={item.meta || ""}
            >
              <span class="chat-item-content">
                <span class="chat-item-title"><%= item.title %></span>
                <span class="chat-item-date"><%= item.meta || "" %></span>
              </span>
            </button>
          <% end %>
        <% end %>
      </div>
    <% else %>
      <div class="sidebar-empty">
        <p><%= Map.get(@sidebar_data, :empty_message, dgettext("ui", "No items")) %></p>
      </div>
    <% end %>
    """
  end

  defp render_nav_sidebar(assigns) do
    ~H"""
    <div class="settings-nav-list">
      <%= for item <- Map.get(@sidebar_data, :items, []) do %>
        <button
          class="settings-nav-entry"
          data-testid="sidebar-open-item"
          data-route={item.route}
          data-item-id={item.id}
          data-open-title={item.title}
          data-open-subtitle={Map.get(@sidebar_data, :subtitle, "")}
          type="button"
          phx-click="open_sidebar_item"
          phx-value-route={item.route}
          phx-value-id={item.id}
          phx-value-title={item.title}
          phx-value-subtitle={Map.get(@sidebar_data, :subtitle, "")}
        >
          <span class="settings-nav-entry-icon"><%= Map.get(item, :icon, "") %></span>
          <span><%= item.title %></span>
        </button>
      <% end %>
    </div>
    """
  end

  defp render_default_sidebar(assigns) do
    ~H"""
    <%= for section <- Map.get(@sidebar_data, :sections, []) do %>
      <section class="sidebar-section">
        <div class="sidebar-section-header">
          <span data-testid="sidebar-section-title"><%= section.title %></span>
        </div>
        <div class="sidebar-section-items">
          <%= for item <- Map.get(section, :items, []) do %>
            <div class="sidebar-list-item"><%= item.title || "" %></div>
          <% end %>
        </div>
      </section>
    <% end %>
    """
  end


  defp sidebar_deletable?(route), do: route in ["post", "media", "scripts", "templates", "chat", "import"]

  defp sidebar_delete_testid("post"), do: "sidebar-delete-post"
  defp sidebar_delete_testid("media"), do: "sidebar-delete-media"
  defp sidebar_delete_testid("scripts"), do: "sidebar-delete-script"
  defp sidebar_delete_testid("templates"), do: "sidebar-delete-template"
  defp sidebar_delete_testid("chat"), do: "sidebar-delete-chat"
  defp sidebar_delete_testid("import"), do: "sidebar-delete-import"
  defp sidebar_delete_testid(route), do: "sidebar-delete-#{route}"

  defp sidebar_delete_title("chat"), do: dgettext("ui", "Delete conversation")
  defp sidebar_delete_title("post"), do: dgettext("ui", "Delete") <> " " <> dgettext("ui", "Post")
  defp sidebar_delete_title("media"), do: dgettext("ui", "Delete") <> " " <> dgettext("ui", "Media")
  defp sidebar_delete_title("scripts"), do: dgettext("ui", "Delete") <> " " <> dgettext("ui", "Script")
  defp sidebar_delete_title("templates"), do: dgettext("ui", "Delete") <> " " <> dgettext("ui", "Template")
  defp sidebar_delete_title("import"), do: dgettext("ui", "Delete") <> " " <> dgettext("ui", "Import")
  defp sidebar_delete_title(_route), do: dgettext("ui", "Delete")

  defp template_sidebar?(sidebar_data), do: Map.get(sidebar_data, :title) == "Templates"

  defp group_year_month_counts(entries) do
    entries
    |> Enum.group_by(& &1.year)
    |> Enum.map(fn {year, months} ->
      %{
        year: year,
        count: Enum.reduce(months, 0, fn entry, acc -> acc + (entry.count || 0) end),
        months: Enum.sort_by(months, &(-&1.month))
      }
    end)
    |> Enum.sort_by(&(-&1.year))
  end

  defp sidebar_filter_tag_color(filters_config, tag) do
    filters_config
    |> Map.get(:available_tag_colors, %{})
    |> Map.get(tag)
    |> normalize_sidebar_filter_color()
  end

  defp sidebar_filter_chip_style(filters_config, tag) do
    case sidebar_filter_tag_color(filters_config, tag) do
      nil ->
        nil

      color ->
        "background-color: #{color}; color: #{sidebar_filter_contrast_color(color)}; border-color: #{color};"
    end
  end

  defp normalize_sidebar_filter_color(nil), do: nil
  defp normalize_sidebar_filter_color(""), do: nil

  defp normalize_sidebar_filter_color("#" <> rest = color) when byte_size(rest) == 6 do
    if String.match?(rest, ~r/\A[0-9a-fA-F]{6}\z/), do: color, else: nil
  end

  defp normalize_sidebar_filter_color(_color), do: nil

  defp sidebar_filter_contrast_color("#" <> rgb) do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = rgb
    {red, _} = Integer.parse(r, 16)
    {green, _} = Integer.parse(g, 16)
    {blue, _} = Integer.parse(b, 16)
    luminance = (red * 299 + green * 587 + blue * 114) / 1000
    if luminance > 150, do: "#1e1e1e", else: "#ffffff"
  end

  defp sidebar_filter_contrast_color(_color), do: "#ffffff"

  defp format_sidebar_timestamp(nil), do: ""

  defp format_sidebar_timestamp(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%x")
  end

  defp image_media?(item), do: String.starts_with?(to_string(item.mime_type || ""), "image/")

  defp media_thumbnail_class(item) do
    if image_media?(item), do: "media-thumbnail has-image", else: "media-thumbnail"
  end

  defp media_thumbnail_glyph(mime_type) do
    case String.split(to_string(mime_type || ""), "/", parts: 2) do
      ["image", _rest] -> "IMG"
      ["video", _rest] -> "VID"
      ["audio", _rest] -> "AUD"
      ["application", _rest] -> "DOC"
      _other -> "FILE"
    end
  end

  defp sidebar_item_selected?(workbench, route, id) do
    route_atom = sidebar_route_atom(route)
    workbench.active_tab == {route_atom, tab_id_for_route(route_atom, id)}
  end

  defp sidebar_route_atom(route) when is_atom(route), do: route

  defp sidebar_route_atom(route) when is_binary(route),
    do: BDS.BoundedAtoms.editor_route(route, :dashboard)

  defp tab_id_for_route(route, id) do
    case Registry.editor_route(route) do
      %{singleton: true} -> Atom.to_string(route)
      _other -> id
    end
  end
end
