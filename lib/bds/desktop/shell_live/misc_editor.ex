defmodule BDS.Desktop.ShellLive.MiscEditor do
  @moduledoc false

  use Phoenix.Component

  alias BDS.{Embeddings, Generation, Git}
  alias BDS.Desktop.ShellData

  embed_templates "misc_editor_html/*"

  @misc_routes [:site_validation, :metadata_diff, :translation_validation, :find_duplicates, :git_diff]

  def assign_socket(socket) do
    assign(socket, :misc_editor, build(socket.assigns))
  end

  def rerun(socket) do
    case meta(socket.assigns) do
      %{action: action} when is_binary(action) -> {:command, action}
      _other -> {:noop, socket}
    end
  end

  def apply_site_validation(socket, append_output) do
    meta = meta(socket.assigns)
    payload = Map.get(meta, :payload, %{})
    project_id = Map.get(meta, :project_id, socket.assigns.projects.active_project_id)
    sections = Enum.map(Map.get(payload, :sections, []), &String.to_existing_atom/1)

    case Generation.apply_validation(project_id, sections) do
      {:ok, result} ->
        {:rerun,
         socket
         |> append_output.(translated("Site Validation"), translated("Validation changes applied"), inspect(result))}
    end
  rescue
    error -> {:socket, append_output.(socket, translated("Site Validation"), inspect(error), nil, "error")}
  end

  def toggle_duplicate(socket, pair_id, reload) do
    selected_by_tab = Map.get(socket.assigns, :misc_editor_selected_pairs, %{})
    current = Map.get(selected_by_tab, socket.assigns.current_tab.id, MapSet.new())

    next =
      if MapSet.member?(current, pair_id) do
        MapSet.delete(current, pair_id)
      else
        MapSet.put(current, pair_id)
      end

    socket
    |> assign(:misc_editor_selected_pairs, Map.put(selected_by_tab, socket.assigns.current_tab.id, next))
    |> reload.(socket.assigns.workbench)
  end

  def dismiss_duplicate(socket, post_id_a, post_id_b, reload, append_output) do
    case Embeddings.dismiss_duplicate_pair(post_id_a, post_id_b) do
      {:ok, _saved_pair} ->
        socket
        |> update_payload(fn payload ->
          update_in(payload[:pairs], fn pairs ->
            Enum.reject(pairs || [], fn pair -> pair_identity(pair) == pair_id(post_id_a, post_id_b) end)
          end)
        end)
        |> clear_selected_pair(pair_id(post_id_a, post_id_b))
        |> append_output.(translated("Find Duplicates"), translated("Pair dismissed"))
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Find Duplicates"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def dismiss_selected(socket, reload, append_output) do
    tab_id = socket.assigns.current_tab.id
    selected =
      socket.assigns.misc_editor_selected_pairs
      |> Map.get(tab_id, MapSet.new())
      |> MapSet.to_list()
      |> Enum.map(&decode_pair_id/1)
      |> Enum.reject(&is_nil/1)

    case Embeddings.dismiss_duplicate_pairs(selected) do
      {:ok, _saved_pairs} ->
        socket
        |> update_payload(fn payload ->
          update_in(payload[:pairs], fn pairs ->
            Enum.reject(pairs || [], fn pair -> pair_identity(pair) in selected end)
          end)
        end)
        |> assign(:misc_editor_selected_pairs, Map.put(socket.assigns.misc_editor_selected_pairs, tab_id, MapSet.new()))
        |> append_output.(translated("Find Duplicates"), translated("Selected pairs dismissed"))
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Find Duplicates"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def metadata_diff_repair_request(socket, field, direction) do
    meta = meta(socket.assigns)
    payload = Map.get(meta, :payload, %{})
    items = Enum.map(Map.get(payload, :diff_reports, []), &normalize_metadata_diff_item/1)
    tabs = metadata_diff_tabs(items, [])
    active_tab = metadata_diff_active_tab(socket.assigns, tabs)

    repair_items =
      items
      |> Enum.filter(&(&1.tab_id == active_tab))
      |> Enum.filter(fn item -> Enum.any?(item.differences, &(diff_name(&1) == field)) end)
      |> Enum.map(&%{"entity_type" => &1.entity_type, "entity_id" => &1.entity_id})

    cond do
      not metadata_diff_repairable_tab?(active_tab) ->
        {:error, translated("No repair action available")}

      repair_items == [] ->
        {:error, translated("No metadata diff items selected")}

      true ->
        {:ok,
         %{
           "direction" => direction,
           "field" => field,
           "tab" => active_tab,
           "items" => repair_items
         }}
    end
  end

  def metadata_diff_orphan_import_request(socket) do
    meta = meta(socket.assigns)
    payload = Map.get(meta, :payload, %{})
    items = Enum.map(Map.get(payload, :diff_reports, []), &normalize_metadata_diff_item/1)
    orphan_files = Enum.map(Map.get(payload, :orphan_reports, []), &normalize_metadata_diff_orphan/1)
    tabs = metadata_diff_tabs(items, orphan_files)
    active_tab = metadata_diff_active_tab(socket.assigns, tabs)

    selected_orphans =
      orphan_files
      |> Enum.filter(&(&1.tab_id == active_tab))
      |> Enum.map(&%{"file_path" => &1.file_path})

    if selected_orphans == [] do
      {:error, translated("No orphan files selected")}
    else
      {:ok, %{"tab" => active_tab, "orphans" => selected_orphans}}
    end
  end

  def build(%{current_tab: %{type: type}} = assigns) when type in @misc_routes do
    meta = meta(assigns)
    payload = Map.get(meta, :payload, %{})

    case type do
      :site_validation -> build_site_validation(meta, payload)
      :metadata_diff -> build_metadata_diff(assigns, meta, payload)
      :translation_validation -> build_translation_validation(meta, payload)
      :find_duplicates -> build_duplicates(assigns, meta, payload)
      :git_diff -> build_git_diff(assigns, meta)
    end
  end

  def build(_assigns), do: nil

  def translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))

  def misc_class(:site_validation), do: "site-validation-view"
  def misc_class(:metadata_diff), do: "metadata-diff-view"
  def misc_class(:translation_validation), do: "translation-validation-view"
  def misc_class(:find_duplicates), do: "duplicates-view"
  def misc_class(:git_diff), do: "git-diff-view"

  def summary_items(%{summary: summary}) when is_map(summary), do: Enum.to_list(summary)
  def summary_items(_misc), do: []

  def duplicate_checked?(misc, pair_id), do: MapSet.member?(misc.selected_pairs, pair_id)

  def pair_id_from_pair(pair), do: pair_identity(pair)

  defp build_site_validation(meta, payload) do
    summary = Map.get(payload, :summary, %{})

    %{
      kind: :site_validation,
      title: Map.get(meta, :title, translated("Site Validation")),
      subtitle: Map.get(meta, :subtitle, ""),
      summary: %{
        expected: Map.get(summary, :missing_count, 0) + Map.get(summary, :extra_count, 0) + Map.get(summary, :stale_count, 0),
        missing: Map.get(summary, :missing_count, 0),
        extra: Map.get(summary, :extra_count, 0),
        stale: Map.get(summary, :stale_count, 0)
      },
      missing_pages: Map.get(payload, :missing_pages, []),
      extra_pages: Map.get(payload, :extra_pages, []),
      stale_pages: Map.get(payload, :stale_pages, []),
      sections: Map.get(payload, :sections, [])
    }
  end

  defp build_metadata_diff(assigns, meta, payload) do
    items = Enum.map(Map.get(payload, :diff_reports, []), &normalize_metadata_diff_item/1)
    orphan_files = Enum.map(Map.get(payload, :orphan_reports, []), &normalize_metadata_diff_orphan/1)
    tabs = metadata_diff_tabs(items, orphan_files)
    active_tab = metadata_diff_active_tab(assigns, tabs)
    active_field = metadata_diff_active_field(assigns)
    current_tab = Enum.find(tabs, &(&1.id == active_tab)) || List.first(tabs) || empty_metadata_diff_tab()
    filtered_items = metadata_diff_filtered_items(current_tab.items, active_field)

    %{
      kind: :metadata_diff,
      title: Map.get(meta, :title, translated("Metadata Diff")),
      subtitle: Map.get(meta, :subtitle, ""),
      summary: Map.get(payload, :summary, %{}),
      tabs: Enum.map(tabs, &Map.take(&1, [:id, :label, :badge_count, :diff_count, :orphan_count])),
      active_tab: current_tab.id,
      active_field: active_field,
      repair_enabled: metadata_diff_repairable_tab?(current_tab.id),
      field_summaries: field_summaries(current_tab.items),
      items: filtered_items,
      orphan_files: if(is_nil(active_field), do: current_tab.orphan_files, else: []),
      empty_message: translated("No items")
    }
  end

  defp build_translation_validation(meta, payload) do
    %{
      kind: :translation_validation,
      title: Map.get(meta, :title, translated("Translation Validation")),
      subtitle: Map.get(meta, :subtitle, ""),
      summary: Map.get(payload, :summary, %{}),
      missing: Map.get(payload, :missing, []),
      orphan_files: Map.get(payload, :orphan_files, []),
      do_not_translate_posts: Map.get(payload, :do_not_translate_posts, [])
    }
  end

  defp build_duplicates(assigns, meta, payload) do
    selected_pairs = Map.get(assigns.misc_editor_selected_pairs, assigns.current_tab.id, MapSet.new())

    %{
      kind: :find_duplicates,
      title: Map.get(meta, :title, translated("Find Duplicates")),
      subtitle: Map.get(meta, :subtitle, ""),
      summary: Map.get(payload, :summary, %{}),
      pairs: Map.get(payload, :pairs, []),
      selected_pairs: selected_pairs
    }
  end

  defp build_git_diff(assigns, meta) do
    diff_text =
      case Git.diff(assigns.projects.active_project_id) do
        {:ok, %{staged_diff: staged, unstaged_diff: unstaged}} ->
          [
            "# Staged Changes\n\n",
            if(String.trim(staged) == "", do: translated("No staged changes"), else: staged),
            "\n\n# Working Tree\n\n",
            if(String.trim(unstaged) == "", do: translated("No unstaged changes"), else: unstaged)
          ]
          |> IO.iodata_to_binary()

        {:error, reason} -> inspect(reason)
      end

    %{
      kind: :git_diff,
      title: Map.get(meta, :title, translated("Git Diff")),
      subtitle: Map.get(meta, :subtitle, ""),
      diff_text: diff_text,
      summary: %{}
    }
  end

  defp meta(assigns) do
    Map.get(assigns.tab_meta, {assigns.current_tab.type, assigns.current_tab.id}, %{})
  end

  defp update_payload(socket, updater) do
    key = {socket.assigns.current_tab.type, socket.assigns.current_tab.id}
    meta = Map.get(socket.assigns.tab_meta, key, %{})
    next_meta = Map.update(meta, :payload, %{}, updater)
    assign(socket, :tab_meta, Map.put(socket.assigns.tab_meta, key, next_meta))
  end

  defp clear_selected_pair(socket, pair_id) do
    tab_id = socket.assigns.current_tab.id
    current = Map.get(socket.assigns.misc_editor_selected_pairs, tab_id, MapSet.new())
    next_pairs = Map.put(socket.assigns.misc_editor_selected_pairs, tab_id, MapSet.delete(current, pair_id))
    assign(socket, :misc_editor_selected_pairs, next_pairs)
  end

  defp pair_id(post_id_a, post_id_b), do: Enum.sort([post_id_a, post_id_b]) |> Enum.join("::")
  defp pair_identity(pair), do: pair_id(Map.get(pair, :post_id_a) || Map.get(pair, "post_id_a"), Map.get(pair, :post_id_b) || Map.get(pair, "post_id_b"))

  defp decode_pair_id(encoded) when is_binary(encoded) do
    case String.split(encoded, "::", parts: 2) do
      [post_id_a, post_id_b] -> {post_id_a, post_id_b}
      _other -> nil
    end
  end

  defp decode_pair_id(_encoded), do: nil

  defp field_summaries(items) do
    items
    |> Enum.flat_map(fn item -> Map.get(item, :differences) || Map.get(item, "differences") || [] end)
    |> Enum.group_by(&diff_name/1)
    |> Enum.map(fn {field, diffs} -> %{field_name: field, diff_count: length(diffs)} end)
    |> Enum.sort_by(&{&1.diff_count * -1, &1.field_name})
  end

  defp metadata_diff_tabs(items, orphan_files) do
    tab_ids =
      (Enum.map(items, & &1.tab_id) ++ Enum.map(orphan_files, & &1.tab_id))
      |> Enum.uniq()
      |> Enum.sort_by(&metadata_diff_tab_sort_key/1)

    if tab_ids == [] do
      [empty_metadata_diff_tab()]
    else
      Enum.map(tab_ids, fn tab_id ->
        tab_items = Enum.filter(items, &(&1.tab_id == tab_id))
        tab_orphans = Enum.filter(orphan_files, &(&1.tab_id == tab_id))

        %{
          id: tab_id,
          label: metadata_diff_tab_label(tab_id),
          items: tab_items,
          orphan_files: tab_orphans,
          diff_count: length(tab_items),
          orphan_count: length(tab_orphans),
          badge_count: length(tab_items) + length(tab_orphans)
        }
      end)
    end
  end

  defp empty_metadata_diff_tab do
    %{id: "posts", label: translated("Posts"), items: [], orphan_files: [], diff_count: 0, orphan_count: 0, badge_count: 0}
  end

  defp metadata_diff_active_tab(assigns, tabs) do
    tab_id = Map.get(assigns.metadata_diff_active_tabs || %{}, assigns.current_tab.id)

    if Enum.any?(tabs, &(&1.id == tab_id)) do
      tab_id
    else
      tabs |> List.first() |> Map.get(:id)
    end
  end

  defp metadata_diff_active_field(assigns) do
    Map.get(assigns.metadata_diff_field_filters || %{}, assigns.current_tab.id)
  end

  defp metadata_diff_filtered_items(items, nil), do: items

  defp metadata_diff_filtered_items(items, field) do
    Enum.filter(items, fn item -> Enum.any?(item.differences, &(diff_name(&1) == field)) end)
  end

  defp normalize_metadata_diff_item(item) do
    entity_type = Map.get(item, :entity_type) || Map.get(item, "entity_type") || "post"
    entity_id = Map.get(item, :entity_id) || Map.get(item, "entity_id") || ""
    differences =
      item
      |> Map.get(:differences, Map.get(item, "differences", []))
      |> Enum.map(&normalize_metadata_diff_difference/1)

    %{
      tab_id: metadata_diff_tab_id(entity_type),
      entity_type: entity_type,
      entity_id: entity_id,
      label: metadata_diff_item_label(item, entity_id),
      display_entity_type: metadata_diff_item_type_label(entity_type),
      differences: differences
    }
  end

  defp normalize_metadata_diff_difference(diff) do
    %{
      field: diff_name(diff),
      db_value: format_metadata_diff_value(Map.get(diff, :db_value) || Map.get(diff, "db_value")),
      file_value: format_metadata_diff_value(Map.get(diff, :file_value) || Map.get(diff, "file_value"))
    }
  end

  defp normalize_metadata_diff_orphan(orphan) do
    path = Map.get(orphan, :file_path) || Map.get(orphan, "file_path") || Map.get(orphan, :path) || Map.get(orphan, "path") || ""
    entity_type = Map.get(orphan, :entity_type) || Map.get(orphan, "entity_type") || metadata_diff_orphan_entity_type(path)

    %{
      tab_id: metadata_diff_tab_id(entity_type),
      entity_type: entity_type,
      file_path: path,
      slug: Path.basename(path) |> String.trim(),
      id: Map.get(orphan, :id) || Map.get(orphan, "id")
    }
  end

  defp metadata_diff_item_label(item, entity_id) do
    Map.get(item, :label) || Map.get(item, "label") || Map.get(item, :title) || Map.get(item, "title") || Map.get(item, :slug) || Map.get(item, "slug") || entity_id
  end

  defp metadata_diff_item_type_label("post"), do: translated("Post")
  defp metadata_diff_item_type_label("post_translation"), do: translated("Translations")
  defp metadata_diff_item_type_label("media"), do: translated("Media")
  defp metadata_diff_item_type_label("media_translation"), do: translated("Translations")
  defp metadata_diff_item_type_label("script"), do: translated("Script")
  defp metadata_diff_item_type_label("template"), do: translated("Template")
  defp metadata_diff_item_type_label("project"), do: translated("Project")
  defp metadata_diff_item_type_label("publishing"), do: translated("Publishing")
  defp metadata_diff_item_type_label("categories"), do: translated("Categories")
  defp metadata_diff_item_type_label("category_meta"), do: translated("Categories")
  defp metadata_diff_item_type_label("embedding"), do: translated("Embeddings")
  defp metadata_diff_item_type_label(entity_type), do: entity_type |> String.replace("_", " ") |> String.capitalize()

  defp metadata_diff_tab_id("post"), do: "posts"
  defp metadata_diff_tab_id("post_translation"), do: "posts"
  defp metadata_diff_tab_id("media"), do: "media"
  defp metadata_diff_tab_id("media_translation"), do: "media"
  defp metadata_diff_tab_id("script"), do: "scripts"
  defp metadata_diff_tab_id("template"), do: "templates"
  defp metadata_diff_tab_id("project"), do: "project"
  defp metadata_diff_tab_id("publishing"), do: "project"
  defp metadata_diff_tab_id("categories"), do: "project"
  defp metadata_diff_tab_id("category_meta"), do: "project"
  defp metadata_diff_tab_id("embedding"), do: "embeddings"
  defp metadata_diff_tab_id(_entity_type), do: "project"

  defp metadata_diff_tab_label("posts"), do: translated("Posts")
  defp metadata_diff_tab_label("media"), do: translated("Media")
  defp metadata_diff_tab_label("scripts"), do: translated("Scripts")
  defp metadata_diff_tab_label("templates"), do: translated("Templates")
  defp metadata_diff_tab_label("project"), do: translated("Project")
  defp metadata_diff_tab_label("embeddings"), do: translated("Embeddings")
  defp metadata_diff_tab_label(tab_id), do: tab_id |> String.replace("_", " ") |> String.capitalize()

  defp metadata_diff_tab_sort_key("posts"), do: 0
  defp metadata_diff_tab_sort_key("media"), do: 1
  defp metadata_diff_tab_sort_key("scripts"), do: 2
  defp metadata_diff_tab_sort_key("templates"), do: 3
  defp metadata_diff_tab_sort_key("project"), do: 4
  defp metadata_diff_tab_sort_key("embeddings"), do: 5
  defp metadata_diff_tab_sort_key(other), do: {6, other}

  defp metadata_diff_orphan_entity_type(path) do
    cond do
      String.starts_with?(path, "posts/") -> "post"
      String.starts_with?(path, "media/") -> "media"
      String.starts_with?(path, "scripts/") -> "script"
      String.starts_with?(path, "templates/") -> "template"
      true -> "project"
    end
  end

  defp metadata_diff_repairable_tab?(tab_id), do: tab_id in ["posts", "media", "scripts", "templates", "project"]

  defp format_metadata_diff_value(nil), do: "-"
  defp format_metadata_diff_value(""), do: "-"
  defp format_metadata_diff_value(value), do: to_string(value)

  defp diff_name(diff) do
    Map.get(diff, :field) || Map.get(diff, "field") || Map.get(diff, :name) || Map.get(diff, "name") || "value"
  end
end
