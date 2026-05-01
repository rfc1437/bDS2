defmodule BDS.Desktop.ShellLive.TaskLocalization do
  @moduledoc false

  alias BDS.Desktop.ShellData

  def localize_task_status(task_status, locale) do
    tasks = Enum.map(Map.get(task_status, :tasks, []), &localize_task(&1, locale))
    active = Enum.filter(tasks, &(&1.status in [:running, :pending]))

    task_status
    |> Map.put(:tasks, tasks)
    |> Map.put(:running_task_message, localized_running_task_message(active, locale))
  end

  def translate_editor_meta(items, locale) do
    Enum.map(items, fn item ->
      item
      |> Map.update(:label, nil, &ShellData.translate(&1, %{}, locale))
      |> Map.update(:value, nil, &translate_editor_meta_value(&1, locale))
    end)
  end

  def translate_for_socket(socket, text) when is_binary(text),
    do: ShellData.translate(text, %{}, socket.assigns.page_language)

  def translate_for_socket(_socket, text), do: text

  def progress_percent(progress) when is_number(progress) do
    percentage = progress |> Kernel.*(100) |> round()
    Integer.to_string(percentage) <> "%"
  end

  def command_title(action) do
    action
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp localize_task(task, locale) do
    progress = Map.get(task, :progress)

    task
    |> Map.put(:name, ShellData.translate(task.name, %{}, locale))
    |> Map.put(:message, localize_task_message(Map.get(task, :message), locale))
    |> Map.put(:group_name, localize_task_group(Map.get(task, :group_name), locale))
    |> Map.put(:status_label, localize_task_status_label(task.status, locale))
    |> Map.put(:progress_label, if(is_number(progress), do: progress_percent(progress), else: nil))
  end

  defp localize_task_message(nil, _locale), do: nil
  defp localize_task_message("", _locale), do: ""
  defp localize_task_message(message, locale), do: ShellData.translate(message, %{}, locale)

  defp localize_task_group(nil, _locale), do: nil
  defp localize_task_group(group, locale), do: ShellData.translate(group, %{}, locale)

  defp localize_task_status_label(status, locale) do
    status
    |> to_string()
    |> String.capitalize()
    |> ShellData.translate(%{}, locale)
  end

  defp localized_running_task_message([], _locale), do: nil

  defp localized_running_task_message([task | _rest], locale) do
    cond do
      task.status == :pending -> ShellData.translate("Queued", %{}, locale) <> ": " <> task.name
      is_binary(task.message) and task.message != "" -> task.name <> ": " <> task.message
      true -> task.name
    end
  end

  defp translate_editor_meta_value(value, locale) when is_binary(value),
    do: ShellData.translate(value, %{}, locale)

  defp translate_editor_meta_value(value, _locale), do: value
end
