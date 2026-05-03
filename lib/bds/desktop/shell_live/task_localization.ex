defmodule BDS.Desktop.ShellLive.TaskLocalization do
  @moduledoc false


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
      |> Map.update(:label, nil, &BDS.Gettext.lgettext(locale, "ui", &1))
      |> Map.update(:value, nil, &translate_editor_meta_value(&1, locale))
    end)
  end

  def translate_for_socket(socket, text) when is_binary(text),
    do: BDS.Gettext.lgettext(socket.assigns.page_language, "ui", text)

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
    |> Map.put(:name, BDS.Gettext.lgettext(locale, "ui", task.name))
    |> Map.put(:message, localize_task_message(Map.get(task, :message), locale))
    |> Map.put(:group_name, localize_task_group(Map.get(task, :group_name), locale))
    |> Map.put(:status_label, localize_task_status_label(task.status, locale))
    |> Map.put(
      :progress_label,
      if(is_number(progress), do: progress_percent(progress), else: nil)
    )
  end

  defp localize_task_message(nil, _locale), do: nil
  defp localize_task_message("", _locale), do: ""
  defp localize_task_message(message, locale), do: BDS.Gettext.lgettext(locale, "ui", message)

  defp localize_task_group(nil, _locale), do: nil
  defp localize_task_group(group, locale), do: BDS.Gettext.lgettext(locale, "ui", group)

  defp localize_task_status_label(status, locale) do
    status
    |> to_string()
    |> String.capitalize()
    |> then(&BDS.Gettext.lgettext(locale, "ui", &1))
  end

  defp localized_running_task_message([], _locale), do: nil

  defp localized_running_task_message([task | _rest], locale) do
    cond do
      task.status == :pending -> BDS.Gettext.lgettext(locale, "ui", "Queued") <> ": " <> task.name
      is_binary(task.message) and task.message != "" -> task.name <> ": " <> task.message
      true -> task.name
    end
  end

  defp translate_editor_meta_value(value, locale) when is_binary(value),
    do: BDS.Gettext.lgettext(locale, "ui", value)

  defp translate_editor_meta_value(value, _locale), do: value
end
