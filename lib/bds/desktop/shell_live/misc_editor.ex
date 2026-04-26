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

      {:error, reason} -> {:socket, append_output.(socket, translated("Site Validation"), inspect(reason), nil, "error")}
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

  def build(%{current_tab: %{type: type}} = assigns) when type in @misc_routes do
    meta = meta(assigns)
    payload = Map.get(meta, :payload, %{})

    case type do
      :site_validation -> build_site_validation(meta, payload)
      :metadata_diff -> build_metadata_diff(meta, payload)
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

  defp build_metadata_diff(meta, payload) do
    items = Map.get(payload, :diff_reports, [])

    %{
      kind: :metadata_diff,
      title: Map.get(meta, :title, translated("Metadata Diff")),
      subtitle: Map.get(meta, :subtitle, ""),
      summary: Map.get(payload, :summary, %{}),
      field_summaries: field_summaries(items),
      items: items,
      orphan_files: Map.get(payload, :orphan_reports, [])
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
    |> Enum.group_by(fn diff -> Map.get(diff, :field) || Map.get(diff, "field") end)
    |> Enum.map(fn {field, diffs} -> %{field_name: field, diff_count: length(diffs)} end)
    |> Enum.sort_by(&{&1.diff_count * -1, &1.field_name})
  end
end
