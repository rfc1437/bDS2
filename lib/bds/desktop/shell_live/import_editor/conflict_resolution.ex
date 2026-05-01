defmodule BDS.Desktop.ShellLive.ImportEditor.ConflictResolution do
  @moduledoc false

  alias BDS.ImportDefinitions

  def change_conflict_resolution(socket, %{"item_type" => item_type, "item_name" => item_name, "resolution" => resolution}, reload) do
    with %{id: definition_id} <- socket.assigns.current_tab,
         %{} = definition <- ImportDefinitions.get_definition(definition_id),
         %{} = report <- ImportDefinitions.decode_analysis_result(definition),
         updated_report <- update_conflict_resolution(report, item_type, item_name, resolution),
         {:ok, _definition} <- ImportDefinitions.update_definition(definition_id, %{last_analysis_result: updated_report}) do
      reload.(socket, socket.assigns.workbench)
    else
      _other -> reload.(socket, socket.assigns.workbench)
    end
  end

  def update_conflict_resolution(report, item_type, item_name, resolution) do
    report
    |> update_in([:conflicts], fn conflicts ->
      Enum.map(conflicts || [], fn conflict ->
        if conflict.item_type == item_type and conflict.item_name == item_name do
          %{conflict | resolution: resolution}
        else
          conflict
        end
      end)
    end)
    |> update_in([:items], &update_conflict_bucket(&1, item_type, item_name, resolution))
    |> update_in([:details], &update_conflict_bucket(&1, item_type, item_name, resolution))
  end

  def update_conflict_bucket(nil, _item_type, _item_name, _resolution), do: nil

  def update_conflict_bucket(buckets, item_type, item_name, resolution) do
    bucket_key = if(item_type == "page", do: :pages, else: if(item_type == "media", do: :media, else: :posts))

    update_in(buckets, [bucket_key], fn items ->
      Enum.map(items || [], fn item ->
        identity = Map.get(item, :slug) || Map.get(item, :filename)

        if identity == item_name do
          Map.put(item, :resolution, resolution)
        else
          item
        end
      end)
    end)
  end
end
