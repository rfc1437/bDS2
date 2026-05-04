defmodule BDS.Desktop.ShellLive.MiscEditor do
  @moduledoc false

  use Phoenix.LiveComponent

  import Ecto.Query

  alias BDS.{Embeddings, Generation, Git, Posts, Repo}
  alias BDS.MapUtils
  alias BDS.Settings.Setting
  use Gettext, backend: BDS.Gettext

  embed_templates("misc_editor_html/*")

  @misc_routes [
    :site_validation,
    :metadata_diff,
    :translation_validation,
    :find_duplicates,
    :git_diff
  ]

  # ── LiveComponent lifecycle ────────────────────────────────────────────────

  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{current_tab: current_tab, tab_meta: tab_meta, project_id: project_id}, socket) do
    socket =
      socket
      |> assign(:current_tab, current_tab)
      |> assign(:project_id, project_id)
      |> assign(:tab_meta, tab_meta)
      |> ensure_state()
      |> build_data()

    {:ok, socket}
  end

  defp ensure_state(socket) do
    socket
    |> assign_new(:selected_pairs, fn -> MapSet.new() end)
    |> assign_new(:git_selected_file, fn -> nil end)
    |> assign_new(:active_tab, fn -> nil end)
    |> assign_new(:active_field, fn -> nil end)
  end

  defp build_data(socket) do
    misc_editor = do_build(socket.assigns)
    assign(socket, :misc_editor, misc_editor)
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(assigns) do
    misc_editor(assigns)
  end

  # ── Event handlers ─────────────────────────────────────────────────────────

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("rerun_misc_editor", _params, socket) do
    action = rerun_action(socket.assigns)

    if action do
      notify_command(action)
    end

    {:noreply, socket}
  end

  def handle_event("apply_site_validation", _params, socket) do
    meta = meta(socket.assigns)
    payload = Map.get(meta, :payload, %{})
    project_id = Map.get(meta, :project_id, socket.assigns.project_id)

    report = %{
      sitemap_path: Map.get(payload, :sitemap_path),
      sitemap_changed: Map.get(payload, :sitemap_changed, false),
      missing_url_paths: Map.get(payload, :missing_url_paths, []),
      extra_url_paths: Map.get(payload, :extra_url_paths, []),
      updated_post_url_paths: Map.get(payload, :updated_post_url_paths, []),
      expected_url_count: Map.get(payload, :expected_url_count, 0),
      existing_html_url_count: Map.get(payload, :existing_html_url_count, 0)
    }

    case Generation.apply_validation(project_id, report) do
      {:ok, result} ->
        notify_output(
          dgettext("ui", "Site Validation"),
          dgettext("ui", "Validation changes applied"),
          inspect(result)
        )

        notify_command("validate_site")
        {:noreply, socket}
    end
  rescue
    error ->
      notify_output(dgettext("ui", "Site Validation"), inspect(error), nil, "error")
      {:noreply, socket}
  end

  def handle_event("fix_translation_validation", _params, socket) do
    report =
      socket.assigns
      |> meta()
      |> Map.get(:payload, %{})
      |> normalize_translation_validation_report()

    {:ok, result} = Posts.fix_invalid_translations(report)

    notify_output(
      dgettext("ui", "Translation Validation"),
      dgettext(
        "ui",
        "Deleted %{dbRows} DB rows and %{files} files, flushed %{flushed} translations to disk",
        dbRows: result.deleted_database_rows,
        files: result.deleted_files,
        flushed: result.flushed_translations
      )
    )

    notify_command("validate_translations")
    {:noreply, socket}
  rescue
    error ->
      notify_output(dgettext("ui", "Translation Validation"), inspect(error), nil, "error")
      {:noreply, socket}
  end

  def handle_event("select_git_diff_file", %{"path" => path}, socket) do
    {:noreply, assign(socket, :git_selected_file, path) |> build_data()}
  end

  def handle_event("toggle_duplicate_pair", %{"pair-id" => pair_id}, socket) do
    current = socket.assigns.selected_pairs

    next =
      if MapSet.member?(current, pair_id) do
        MapSet.delete(current, pair_id)
      else
        MapSet.put(current, pair_id)
      end

    {:noreply, assign(socket, :selected_pairs, next) |> build_data()}
  end

  def handle_event(
        "dismiss_duplicate_pair",
        %{"post-id-a" => post_id_a, "post-id-b" => post_id_b},
        socket
      ) do
    case Embeddings.dismiss_duplicate_pair(post_id_a, post_id_b) do
      {:ok, _saved_pair} ->
        tab_type = socket.assigns.current_tab.type
        tab_id = socket.assigns.current_tab.id
        pair_id = pair_id(post_id_a, post_id_b)

        payload = Map.get(meta(socket.assigns), :payload, %{})

        next_pairs =
          update_in(payload[:pairs], fn pairs ->
            Enum.reject(pairs || [], fn pair ->
              pair_identity(pair) == pair_id
            end)
          end)

        next_payload = Map.put(payload, :pairs, next_pairs)
        notify_tab_meta(tab_type, tab_id, %{payload: next_payload})
        notify_output(dgettext("ui", "Find Duplicates"), dgettext("ui", "Pair dismissed"))

        selected = MapSet.delete(socket.assigns.selected_pairs, pair_id)
        {:noreply, assign(socket, :selected_pairs, selected) |> build_data()}

      {:error, reason} ->
        notify_output(dgettext("ui", "Find Duplicates"), inspect(reason), nil, "error")
        {:noreply, socket}
    end
  end

  def handle_event("dismiss_selected_duplicates", _params, socket) do
    selected =
      socket.assigns.selected_pairs
      |> MapSet.to_list()
      |> Enum.map(&decode_pair_id/1)
      |> Enum.reject(&is_nil/1)

    case Embeddings.dismiss_duplicate_pairs(selected) do
      {:ok, _saved_pairs} ->
        tab_type = socket.assigns.current_tab.type
        tab_id = socket.assigns.current_tab.id
        payload = Map.get(meta(socket.assigns), :payload, %{})

        next_pairs =
          update_in(payload[:pairs], fn pairs ->
            Enum.reject(pairs || [], fn pair -> pair_identity(pair) in selected end)
          end)

        next_payload = Map.put(payload, :pairs, next_pairs)
        notify_tab_meta(tab_type, tab_id, %{payload: next_payload})

        notify_output(
          dgettext("ui", "Find Duplicates"),
          dgettext("ui", "Selected pairs dismissed")
        )

        {:noreply, assign(socket, :selected_pairs, MapSet.new()) |> build_data()}

      {:error, reason} ->
        notify_output(dgettext("ui", "Find Duplicates"), inspect(reason), nil, "error")
        {:noreply, socket}
    end
  end

  def handle_event("repair_metadata_diff", %{"field" => field, "direction" => direction}, socket) do
    case metadata_diff_repair_request(socket.assigns, field, direction) do
      {:ok, params} ->
        notify_command("repair_metadata_diff", params)
        {:noreply, socket}

      {:error, message} ->
        notify_output(dgettext("ui", "Metadata Diff"), message, nil, "error")
        {:noreply, socket}
    end
  end

  def handle_event("import_metadata_diff_orphans", _params, socket) do
    case metadata_diff_orphan_import_request(socket.assigns) do
      {:ok, params} ->
        notify_command("import_metadata_diff_orphans", params)
        {:noreply, socket}

      {:error, message} ->
        notify_output(dgettext("ui", "Metadata Diff"), message, nil, "error")
        {:noreply, socket}
    end
  end

  def handle_event("select_metadata_diff_tab", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:active_field, nil)
     |> build_data()}
  end

  def handle_event("toggle_metadata_diff_field", %{"field" => field}, socket) do
    current = socket.assigns.active_field
    next = if current == field, do: nil, else: field
    {:noreply, assign(socket, :active_field, next) |> build_data()}
  end

  def handle_event("open_duplicate_post", %{"id" => id, "title" => title}, socket) do
    notify_open_sidebar_item(
      %{"route" => "post", "id" => id, "title" => title, "subtitle" => "draft"},
      :preview
    )

    {:noreply, socket}
  end

  # ── Public helper functions (used by template) ─────────────────────────────

  @spec misc_class(atom()) :: String.t()
  def misc_class(:site_validation), do: "site-validation-view"
  def misc_class(:metadata_diff), do: "metadata-diff-view"
  def misc_class(:translation_validation), do: "translation-validation-view"
  def misc_class(:find_duplicates), do: "duplicates-view"
  def misc_class(:git_diff), do: "git-diff-view"

  @spec summary_items(map()) :: [{String.t(), any()}]
  def summary_items(%{summary: summary}) when is_map(summary), do: Enum.to_list(summary)
  def summary_items(_misc), do: []

  @spec duplicate_checked?(map(), String.t()) :: boolean()
  def duplicate_checked?(misc, pair_id), do: MapSet.member?(misc.selected_pairs, pair_id)

  @spec pair_id_from_pair(map()) :: String.t()
  def pair_id_from_pair(pair), do: pair_identity(pair)

  @spec translation_issue_label(map()) :: String.t()
  def translation_issue_label(issue) do
    case issue_value(issue, :issue) do
      "same-language-as-canonical" ->
        dgettext("ui", "Translation language matches canonical post language")

      "do-not-translate-has-translations" ->
        dgettext("ui", "Post is marked as do-not-translate but has translations")

      "content-in-database" ->
        dgettext("ui", "Published translation has content stuck in DB instead of filesystem")

      _other ->
        dgettext("ui", "Translation points to a missing source post")
    end
  end

  @spec translation_issue_languages(map()) :: String.t()
  def translation_issue_languages(issue) do
    canonical_language = issue_value(issue, :canonical_language)
    translation_language = issue_value(issue, :translation_language)

    if canonical_language in [nil, ""] do
      translation_language
    else
      dgettext("ui", "%{canonical} = %{translation}",
        canonical: canonical_language,
        translation: translation_language
      )
    end
  end

  @spec translation_issue_value(map(), atom() | String.t()) :: any()
  def translation_issue_value(issue, key), do: issue_value(issue, key)

  @spec git_diff_language(String.t() | nil) :: String.t()
  def git_diff_language(nil), do: "plaintext"

  def git_diff_language(file_path) do
    case file_path |> Path.extname() |> String.downcase() do
      ".md" -> "markdown"
      ".markdown" -> "markdown"
      ".mdx" -> "markdown"
      ".ts" -> "typescript"
      ".tsx" -> "typescript"
      ".js" -> "javascript"
      ".jsx" -> "javascript"
      ".json" -> "json"
      ".css" -> "css"
      ".html" -> "html"
      ".yml" -> "yaml"
      ".yaml" -> "yaml"
      _other -> "plaintext"
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp notify_command(action, params \\ %{}) do
    send(self(), {:misc_editor_command, action, params})
  end

  defp notify_output(title, message, detail \\ nil, level \\ "info") do
    send(self(), {:misc_editor_output, title, message, detail, level})
  end

  defp notify_tab_meta(tab_type, tab_id, updates) do
    send(self(), {:misc_editor_tab_meta, tab_type, tab_id, updates})
  end

  defp notify_open_sidebar_item(params, intent) do
    send(self(), {:open_sidebar_item, params, intent})
  end

  defp rerun_action(assigns) do
    case meta(assigns) do
      %{action: action} when is_binary(action) ->
        action

      _other ->
        misc_route_action(assigns.current_tab.type)
    end
  end

  defp do_build(%{current_tab: %{type: type}} = assigns) when type in @misc_routes do
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

  defp do_build(_assigns), do: nil

  defp build_site_validation(meta, payload) do
    summary = Map.get(payload, :summary, %{})

    %{
      kind: :site_validation,
      title: Map.get(meta, :title, dgettext("ui", "Site Validation")),
      subtitle: Map.get(meta, :subtitle, ""),
      summary: %{
        expected: Map.get(summary, :expected_count, 0),
        existing: Map.get(summary, :existing_count, 0),
        missing: Map.get(summary, :missing_count, 0),
        extra: Map.get(summary, :extra_count, 0),
        updated: Map.get(summary, :updated_count, 0)
      },
      sitemap_path: Map.get(payload, :sitemap_path),
      sitemap_changed: Map.get(payload, :sitemap_changed, false),
      missing_url_paths: Map.get(payload, :missing_url_paths, []),
      extra_url_paths: Map.get(payload, :extra_url_paths, []),
      updated_post_url_paths: Map.get(payload, :updated_post_url_paths, []),
      expected_url_count: Map.get(payload, :expected_url_count, 0),
      existing_html_url_count: Map.get(payload, :existing_html_url_count, 0)
    }
  end

  defp build_metadata_diff(assigns, meta, payload) do
    items = Enum.map(Map.get(payload, :diff_reports, []), &normalize_metadata_diff_item/1)

    orphan_files =
      Enum.map(Map.get(payload, :orphan_reports, []), &normalize_metadata_diff_orphan/1)

    tabs = metadata_diff_tabs(items, orphan_files)
    active_tab = assigns.active_tab || metadata_diff_active_tab_fallback(tabs)
    active_field = assigns.active_field

    current_tab =
      Enum.find(tabs, &(&1.id == active_tab)) || List.first(tabs) || empty_metadata_diff_tab()

    filtered_items = metadata_diff_filtered_items(current_tab.items, active_field)

    %{
      kind: :metadata_diff,
      title: Map.get(meta, :title, dgettext("ui", "Metadata Diff")),
      subtitle: Map.get(meta, :subtitle, ""),
      summary: Map.get(payload, :summary, %{}),
      tabs:
        Enum.map(tabs, &Map.take(&1, [:id, :label, :badge_count, :diff_count, :orphan_count])),
      active_tab: current_tab.id,
      active_field: active_field,
      repair_enabled: metadata_diff_repairable_tab?(current_tab.id),
      field_summaries: field_summaries(current_tab.items),
      items: filtered_items,
      orphan_files: if(is_nil(active_field), do: current_tab.orphan_files, else: []),
      empty_message: dgettext("ui", "No items")
    }
  end

  defp build_translation_validation(meta, payload) do
    report = normalize_translation_validation_report(payload)

    %{
      kind: :translation_validation,
      title: Map.get(meta, :title, dgettext("ui", "Translation Validation")),
      subtitle: Map.get(meta, :subtitle, ""),
      summary: %{},
      summary_text:
        dgettext(
          "ui",
          "Checked DB rows: %{dbRows} · Checked files: %{files} · Invalid DB rows: %{invalidDb} · Invalid files: %{invalidFiles}",
          dbRows: report.checked_database_row_count,
          files: report.checked_filesystem_file_count,
          invalidDb: length(report.invalid_database_rows),
          invalidFiles: length(report.invalid_filesystem_files)
        ),
      invalid_database_rows: report.invalid_database_rows,
      invalid_filesystem_files: report.invalid_filesystem_files,
      can_fix?: report.invalid_database_rows != [] or report.invalid_filesystem_files != []
    }
  end

  defp build_duplicates(assigns, meta, payload) do
    %{
      kind: :find_duplicates,
      title: Map.get(meta, :title, dgettext("ui", "Find Duplicates")),
      subtitle: Map.get(meta, :subtitle, ""),
      summary: Map.get(payload, :summary, %{}),
      pairs: Map.get(payload, :pairs, []),
      selected_pairs: assigns.selected_pairs
    }
  end

  defp build_git_diff(assigns, meta) do
    project_id = assigns.project_id
    selected_file = assigns.git_selected_file

    {files, diff, error_message} =
      case Git.status(project_id) do
        {:ok, %{files: files}} ->
          file_paths =
            files
            |> Enum.map(&Map.get(&1, :path))
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
            |> Enum.sort()

          selected_file_path =
            if selected_file in file_paths do
              selected_file
            else
              List.first(file_paths)
            end

          diff =
            case selected_file_path do
              nil ->
                empty_git_diff(project_id)

              file_path ->
                case Git.get_diff_content(project_id, file_path) do
                  {:ok, diff} ->
                    diff

                  {:error, reason} ->
                    Map.merge(empty_git_diff(project_id), %{
                      file_path: file_path,
                      error: inspect(reason)
                    })
                end
            end

          {file_paths, diff, nil}

        {:error, reason} ->
          {[], empty_git_diff(project_id), inspect(reason)}
      end

    preferences = git_diff_preferences()

    %{
      kind: :git_diff,
      title: Map.get(meta, :title, dgettext("ui", "Git Diff")),
      subtitle: Map.get(meta, :subtitle, ""),
      summary: %{},
      files: files,
      selected_file_path: diff.file_path,
      active_diff: Map.put(diff, :language, git_diff_language(diff.file_path)),
      preferences: preferences,
      empty_message: error_message || dgettext("ui", "No unstaged changes")
    }
  end

  defp meta(assigns) do
    Map.get(assigns.tab_meta, {assigns.current_tab.type, assigns.current_tab.id}, %{})
  end

  defp metadata_diff_repair_request(assigns, field, direction) do
    payload = Map.get(meta(assigns), :payload, %{})
    items = Enum.map(Map.get(payload, :diff_reports, []), &normalize_metadata_diff_item/1)
    tabs = metadata_diff_tabs(items, [])
    active_tab = assigns.active_tab || metadata_diff_active_tab_fallback(tabs)

    repair_items =
      items
      |> Enum.filter(&(&1.tab_id == active_tab))
      |> Enum.filter(fn item -> Enum.any?(item.differences, &(diff_name(&1) == field)) end)
      |> Enum.map(&%{"entity_type" => &1.entity_type, "entity_id" => &1.entity_id})

    cond do
      not metadata_diff_repairable_tab?(active_tab) ->
        {:error, dgettext("ui", "No repair action available")}

      repair_items == [] ->
        {:error, dgettext("ui", "No metadata diff items selected")}

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

  defp metadata_diff_orphan_import_request(assigns) do
    payload = Map.get(meta(assigns), :payload, %{})
    items = Enum.map(Map.get(payload, :diff_reports, []), &normalize_metadata_diff_item/1)

    orphan_files =
      Enum.map(Map.get(payload, :orphan_reports, []), &normalize_metadata_diff_orphan/1)

    tabs = metadata_diff_tabs(items, orphan_files)
    active_tab = assigns.active_tab || metadata_diff_active_tab_fallback(tabs)

    selected_orphans =
      orphan_files
      |> Enum.filter(&(&1.tab_id == active_tab))
      |> Enum.map(&%{"file_path" => &1.file_path})

    if selected_orphans == [] do
      {:error, dgettext("ui", "No orphan files selected")}
    else
      {:ok, %{"tab" => active_tab, "orphans" => selected_orphans}}
    end
  end

  defp pair_id(post_id_a, post_id_b), do: Enum.sort([post_id_a, post_id_b]) |> Enum.join("::")

  defp pair_identity(pair),
    do: pair_id(MapUtils.attr(pair, :post_id_a), MapUtils.attr(pair, :post_id_b))

  defp decode_pair_id(encoded) when is_binary(encoded) do
    case String.split(encoded, "::", parts: 2) do
      [post_id_a, post_id_b] -> {post_id_a, post_id_b}
      _other -> nil
    end
  end

  defp decode_pair_id(_encoded), do: nil

  defp field_summaries(items) do
    items
    |> Enum.flat_map(fn item -> MapUtils.attr(item, :differences) || [] end)
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
    %{
      id: "posts",
      label: dgettext("ui", "Posts"),
      items: [],
      orphan_files: [],
      diff_count: 0,
      orphan_count: 0,
      badge_count: 0
    }
  end

  defp metadata_diff_active_tab_fallback(tabs) do
    tabs |> List.first() |> Map.get(:id)
  end

  defp metadata_diff_filtered_items(items, nil), do: items

  defp metadata_diff_filtered_items(items, field) do
    Enum.filter(items, fn item -> Enum.any?(item.differences, &(diff_name(&1) == field)) end)
  end

  defp normalize_metadata_diff_item(item) do
    entity_type = MapUtils.attr(item, :entity_type) || "post"
    entity_id = MapUtils.attr(item, :entity_id) || ""

    differences =
      item
      |> MapUtils.attr(:differences, [])
      |> Enum.map(&normalize_metadata_diff_difference/1)

    %{
      tab_id: metadata_diff_tab_id(entity_type),
      entity_type: entity_type,
      entity_id: entity_id,
      label: metadata_diff_item_label(item, entity_id),
      meta_label: metadata_diff_item_meta_label(item, entity_id),
      display_entity_type: metadata_diff_item_type_label(entity_type),
      differences: differences
    }
  end

  defp normalize_metadata_diff_difference(diff) do
    %{
      field: diff_name(diff),
      db_value: format_metadata_diff_value(MapUtils.attr(diff, :db_value)),
      file_value: format_metadata_diff_value(MapUtils.attr(diff, :file_value))
    }
  end

  defp normalize_metadata_diff_orphan(orphan) do
    path = MapUtils.attr(orphan, :file_path) || MapUtils.attr(orphan, :path) || ""
    entity_type = MapUtils.attr(orphan, :entity_type) || metadata_diff_orphan_entity_type(path)

    %{
      tab_id: metadata_diff_tab_id(entity_type),
      entity_type: entity_type,
      file_path: path,
      slug: Path.basename(path) |> String.trim(),
      id: MapUtils.attr(orphan, :id)
    }
  end

  defp metadata_diff_item_label(item, entity_id) do
    MapUtils.attr(item, :label) || MapUtils.attr(item, :title) || MapUtils.attr(item, :slug) ||
      entity_id
  end

  defp metadata_diff_item_meta_label(item, entity_id) do
    MapUtils.attr(item, :meta_label) || entity_id
  end

  defp metadata_diff_item_type_label("post"), do: dgettext("ui", "Post")
  defp metadata_diff_item_type_label("post_translation"), do: dgettext("ui", "Translations")
  defp metadata_diff_item_type_label("media"), do: dgettext("ui", "Media")
  defp metadata_diff_item_type_label("media_translation"), do: dgettext("ui", "Translations")
  defp metadata_diff_item_type_label("script"), do: dgettext("ui", "Script")
  defp metadata_diff_item_type_label("template"), do: dgettext("ui", "Template")
  defp metadata_diff_item_type_label("project"), do: dgettext("ui", "Project")
  defp metadata_diff_item_type_label("publishing"), do: dgettext("ui", "Publishing")
  defp metadata_diff_item_type_label("categories"), do: dgettext("ui", "Categories")
  defp metadata_diff_item_type_label("category_meta"), do: dgettext("ui", "Categories")
  defp metadata_diff_item_type_label("embedding"), do: dgettext("ui", "Embeddings")

  defp metadata_diff_item_type_label(entity_type),
    do: entity_type |> String.replace("_", " ") |> String.capitalize()

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

  defp metadata_diff_tab_label("posts"), do: dgettext("ui", "Posts")
  defp metadata_diff_tab_label("media"), do: dgettext("ui", "Media")
  defp metadata_diff_tab_label("scripts"), do: dgettext("ui", "Scripts")
  defp metadata_diff_tab_label("templates"), do: dgettext("ui", "Templates")
  defp metadata_diff_tab_label("project"), do: dgettext("ui", "Project")
  defp metadata_diff_tab_label("embeddings"), do: dgettext("ui", "Embeddings")

  defp metadata_diff_tab_label(tab_id),
    do: tab_id |> String.replace("_", " ") |> String.capitalize()

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

  defp metadata_diff_repairable_tab?(tab_id),
    do: tab_id in ["posts", "media", "scripts", "templates", "project", "embeddings"]

  defp misc_route_action(:site_validation), do: "validate_site"
  defp misc_route_action(:metadata_diff), do: "metadata_diff"
  defp misc_route_action(:translation_validation), do: "validate_translations"
  defp misc_route_action(:find_duplicates), do: "find_duplicates"
  defp misc_route_action(_route), do: nil

  defp format_metadata_diff_value(nil), do: "-"
  defp format_metadata_diff_value(""), do: "-"
  defp format_metadata_diff_value(value), do: to_string(value)

  defp diff_name(diff) do
    MapUtils.attr(diff, :field) || MapUtils.attr(diff, :name) || "value"
  end

  defp normalize_translation_validation_report(payload) when is_map(payload) do
    %{
      checked_database_row_count: issue_value(payload, :checked_database_row_count) || 0,
      checked_filesystem_file_count: issue_value(payload, :checked_filesystem_file_count) || 0,
      invalid_database_rows:
        payload
        |> issue_value(:invalid_database_rows)
        |> List.wrap(),
      invalid_filesystem_files:
        payload
        |> issue_value(:invalid_filesystem_files)
        |> List.wrap()
    }
  end

  defp normalize_translation_validation_report(_payload) do
    %{
      checked_database_row_count: 0,
      checked_filesystem_file_count: 0,
      invalid_database_rows: [],
      invalid_filesystem_files: []
    }
  end

  defp issue_value(issue, key) when is_map(issue) do
    Map.get(issue, key) || Map.get(issue, Atom.to_string(key))
  end

  defp issue_value(_issue, _key), do: nil

  defp empty_git_diff(file_path) do
    %{file_path: file_path, original: "", modified: "", error: nil}
  end

  defp git_diff_preferences do
    %{
      view_style: get_global_setting("ui.git_diff_view_style") || "inline",
      word_wrap: get_global_setting("ui.git_diff_word_wrap") == "true",
      hide_unchanged_regions: get_global_setting("ui.git_diff_hide_unchanged_regions") == "true"
    }
  end

  defp get_global_setting(key) do
    Repo.one(from setting in Setting, where: setting.key == ^key, select: setting.value)
  end
end
