defmodule BDS.Desktop.ShellLive.ImportEditor.TaxonomyEditing do
  @moduledoc false

  alias BDS.{AI, ImportDefinitions, Metadata, Tags}
  alias BDS.Desktop.ShellData

  def start_taxonomy_edit(socket, %{"type" => type, "name" => name, "mapped_to" => mapped_to}, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab do
      socket
      |> Phoenix.Component.assign(
        :import_editor_taxonomy_edits,
        Map.put(socket.assigns.import_editor_taxonomy_edits, definition_id, %{
          type: type,
          name: name,
          value: mapped_to |> to_string() |> blank_to_nil()
        })
      )
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def cancel_taxonomy_edit(socket, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab do
      socket
      |> Phoenix.Component.assign(:import_editor_taxonomy_edits, Map.delete(socket.assigns.import_editor_taxonomy_edits, definition_id))
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def save_taxonomy_edit(socket, %{"type" => type, "name" => name, "mapped_to" => mapped_to}, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id),
         %{} = report <- ImportDefinitions.decode_analysis_result(definition),
         normalized_value <- normalize_taxonomy_mapping_value(socket.assigns.projects.active_project_id, type, mapped_to),
         updated_report <- update_taxonomy_mapping(report, type, name, normalized_value),
         {:ok, _definition} <- ImportDefinitions.update_definition(definition_id, %{last_analysis_result: updated_report}) do
      socket
      |> Phoenix.Component.assign(:import_editor_taxonomy_edits, Map.delete(socket.assigns.import_editor_taxonomy_edits, definition_id))
      |> reload.(socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def clear_taxonomy_mapping(socket, %{"type" => type, "name" => name}, reload) do
    save_taxonomy_edit(socket, %{"type" => type, "name" => name, "mapped_to" => ""}, reload)
  end

  def analyze_taxonomy_ai(socket, reload, append_output) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id),
         %{} = report <- ImportDefinitions.decode_analysis_result(definition) do
      cond do
        socket.assigns.offline_mode ->
          socket
          |> append_output.(translated("activity.import"), ShellData.translate("Automatic AI actions stay gated by airplane mode.", %{}, socket.assigns.page_language), nil, "info")
          |> reload.(socket.assigns.workbench)

        true ->
          taxonomy_terms = existing_taxonomy_terms(socket.assigns.projects.active_project_id)

          import_terms = %{
            categories: Enum.map(Map.get(report.items, :categories, []), & &1.name),
            tags: Enum.map(Map.get(report.items, :tags, []), & &1.name)
          }

          opts = maybe_put_option([], :model, Map.get(socket.assigns.import_editor_selected_models, definition_id))

          case AI.analyze_import_taxonomy(import_terms, taxonomy_terms, opts) do
            {:ok, analysis} ->
              updated_report = apply_taxonomy_mappings(report, analysis)
              {:ok, _definition} = ImportDefinitions.update_definition(definition_id, %{last_analysis_result: updated_report})
              mapped_count = auto_mapped_count(report, updated_report)

              socket
              |> append_output.(translated("activity.import"), translated("importAnalysis.mappedCount", %{count: mapped_count}), Map.get(socket.assigns.import_editor_selected_models, definition_id), "info")
              |> reload.(socket.assigns.workbench)

            {:error, reason} ->
              socket
              |> append_output.(translated("activity.import"), inspect(reason), Map.get(socket.assigns.import_editor_selected_models, definition_id), "error")
              |> reload.(socket.assigns.workbench)
          end
      end
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def update_taxonomy_mapping(report, type, name, mapped_to) do
    bucket_key = if(type == "categories", do: :categories, else: :tags)
    normalized_value = mapped_to |> to_string() |> String.trim() |> blank_to_nil()

    updated_report =
      update_in(report, [:items, bucket_key], fn items ->
        Enum.map(items || [], fn item ->
          if item.name == name do
            %{item | mapped_to: normalized_value}
          else
            item
          end
        end)
      end)

    Map.put(updated_report, stat_key(bucket_key), rebuild_taxonomy_stats(get_in(updated_report, [:items, bucket_key]) || []))
  end

  def rebuild_taxonomy_stats(items) do
    %{
      existing_count: Enum.count(items, & &1.exists_in_project),
      mapped_count: Enum.count(items, &(not &1.exists_in_project and present?(&1.mapped_to))),
      new_count: Enum.count(items, &(not &1.exists_in_project and not present?(&1.mapped_to)))
    }
  end

  def stat_key(:categories), do: :category_stats
  def stat_key(:tags), do: :tag_stats

  def apply_taxonomy_mappings(report, analysis) do
    report
    |> update_in([:items, :categories], &apply_taxonomy_mapping_bucket(&1, Map.get(analysis, :category_mappings, %{})))
    |> update_in([:items, :tags], &apply_taxonomy_mapping_bucket(&1, Map.get(analysis, :tag_mappings, %{})))
    |> then(fn updated_report ->
      updated_report
      |> Map.put(:category_stats, rebuild_taxonomy_stats(get_in(updated_report, [:items, :categories]) || []))
      |> Map.put(:tag_stats, rebuild_taxonomy_stats(get_in(updated_report, [:items, :tags]) || []))
    end)
  end

  def apply_taxonomy_mapping_bucket(items, mappings) do
    Enum.map(items || [], fn item ->
      case Map.fetch(mappings, item.name) do
        {:ok, mapped_to} -> %{item | mapped_to: mapped_to}
        :error -> item
      end
    end)
  end

  def existing_taxonomy_terms(project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    %{
      categories: Enum.uniq(Map.get(metadata, :categories, []) || []),
      tags: project_id |> Tags.list_tags() |> Enum.map(& &1.name) |> Enum.uniq()
    }
  end

  def normalize_taxonomy_mapping_value(project_id, type, mapped_to) do
    normalized_value = mapped_to |> to_string() |> String.trim() |> blank_to_nil()

    case normalized_value do
      nil ->
        nil

      value ->
        project_id
        |> existing_taxonomy_terms()
        |> Map.get(String.to_existing_atom(type), [])
        |> Enum.find(fn term -> String.downcase(term) == String.downcase(value) end)
    end
  end

  def auto_mapped_count(previous_report, next_report) do
    previous_count =
      (Map.get(previous_report.items, :categories, []) ++ Map.get(previous_report.items, :tags, []))
      |> Enum.count(&present?(&1.mapped_to))

    next_count =
      (Map.get(next_report.items, :categories, []) ++ Map.get(next_report.items, :tags, []))
      |> Enum.count(&present?(&1.mapped_to))

    max(next_count - previous_count, 0)
  end

  def taxonomy_pill_class(item) do
    cond do
      item.exists_in_project -> "import-taxonomy-pill exists"
      present?(item.mapped_to) -> "import-taxonomy-pill mapped"
      true -> "import-taxonomy-pill new-tax"
    end
  end

  def taxonomy_item_editing?(%{type: type, name: name}, type, name), do: true
  def taxonomy_item_editing?(_edit, _type, _name), do: false

  def taxonomy_mapping_tooltip(item) do
    action =
      if present?(item.mapped_to),
        do: translated("importAnalysis.mappingActionEdit"),
        else: translated("importAnalysis.mappingActionAdd")

    translated("importAnalysis.mappingTooltip", %{action: action})
  end

  def maybe_put_option(opts, _key, nil), do: opts
  def maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
  defp present?(value), do: value not in [nil, ""]
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
