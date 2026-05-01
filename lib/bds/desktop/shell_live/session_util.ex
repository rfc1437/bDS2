defmodule BDS.Desktop.ShellLive.SessionUtil do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.UI.{Session, Workbench}

  @default_new_project_name "New Blog"

  def restore_workbench_session(session_payload) do
    Session.restore(session_payload)
  rescue
    _error -> Workbench.new()
  end

  def next_project_name(projects) do
    existing_names = MapSet.new(Enum.map(projects, & &1.name))

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate =
        if index == 1, do: @default_new_project_name, else: "#{@default_new_project_name} #{index}"

      if MapSet.member?(existing_names, candidate), do: nil, else: candidate
    end)
  end

  def initial_handled_task_results do
    BDS.Tasks.status_snapshot()
    |> Map.get(:tasks, [])
    |> Enum.filter(fn task -> task.status == :completed and is_map(task.result) end)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  def next_completed_task_result(socket, task_status) do
    handled = Map.get(socket.assigns, :handled_task_results, MapSet.new())

    Enum.find(Map.get(task_status, :tasks, []), fn task ->
      task.status == :completed and is_map(task.result) and not MapSet.member?(handled, task.id)
    end)
  end

  def mark_task_result_handled(socket, task_id) do
    handled = Map.get(socket.assigns, :handled_task_results, MapSet.new())
    assign(socket, :handled_task_results, MapSet.put(handled, task_id))
  end
end
