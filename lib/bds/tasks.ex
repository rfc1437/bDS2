defmodule BDS.Tasks do
  @moduledoc false

  use GenServer

  @default_max_concurrent 3
  @default_progress_throttle_ms 250
  @default_recent_finished_limit 10
  @default_finished_task_ttl_ms :timer.hours(1)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def submit_task(name, work, attrs \\ %{})
      when is_binary(name) and is_function(work, 1) and is_map(attrs) do
    GenServer.call(__MODULE__, {:submit_task, name, work, attrs})
  end

  def get_task(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:get_task, task_id})
  end

  def status_snapshot do
    GenServer.call(__MODULE__, :status_snapshot)
  end

  def list_tasks do
    GenServer.call(__MODULE__, :list_tasks)
  end

  def list_running_tasks do
    GenServer.call(__MODULE__, :list_running_tasks)
  end

  def clear_completed do
    GenServer.call(__MODULE__, :clear_completed)
  end

  def clear_finished do
    GenServer.call(__MODULE__, :clear_finished)
  end

  def cancel_task(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:cancel_task, task_id})
  end

  def register_external_task(name, attrs \\ %{}) when is_binary(name) and is_map(attrs) do
    GenServer.call(__MODULE__, {:register_external_task, name, attrs})
  end

  def report_progress(task_id, value, message) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:report_progress, task_id, value, message})
  end

  def complete_task(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:complete_task, task_id})
  end

  def fail_task(task_id, error_message) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:fail_task, task_id, error_message})
  end

  @impl true
  def init(_state) do
    {:ok,
     %{
       tasks: %{},
       queue: [],
       running: %{},
       ref_to_task: %{}
     }}
  end

  @impl true
  def handle_call({:submit_task, name, work, attrs}, _from, state) do
    task = new_task(name, :pending, attrs)
    next_state = put_in(state, [:tasks, task.id], task)

    if map_size(next_state.running) < max_concurrent() do
      {:reply, {:ok, public_task(task)}, start_task(next_state, task.id, work)}
    else
      {:reply, {:ok, public_task(task)},
       %{next_state | queue: next_state.queue ++ [{task.id, work}]}}
    end
  end

  def handle_call({:get_task, task_id}, _from, state) do
    state = prune_expired_finished_tasks(state)
    {:reply, state.tasks[task_id] && public_task(state.tasks[task_id]), state}
  end

  def handle_call(:status_snapshot, _from, state) do
    state = prune_expired_finished_tasks(state)
    {:reply, build_status_snapshot(state), state}
  end

  def handle_call(:list_tasks, _from, state) do
    state = prune_expired_finished_tasks(state)
    {:reply, all_tasks(state) |> Enum.map(&public_task/1), state}
  end

  def handle_call(:list_running_tasks, _from, state) do
    state = prune_expired_finished_tasks(state)
    {:reply, running_tasks(state) |> Enum.map(&public_task/1), state}
  end

  def handle_call(:clear_completed, _from, state) do
    next_tasks =
      state.tasks
      |> Enum.reject(fn {_task_id, task} -> task.status == :completed end)
      |> Map.new()

    {:reply, :ok, %{state | tasks: next_tasks}}
  end

  def handle_call(:clear_finished, _from, state) do
    next_tasks =
      state.tasks
      |> Enum.reject(fn {_task_id, task} -> task.status in [:completed, :failed, :cancelled] end)
      |> Map.new()

    {:reply, :ok, %{state | tasks: next_tasks}}
  end

  def handle_call({:cancel_task, task_id}, _from, state) do
    cond do
      Map.has_key?(state.running, task_id) ->
        %{pid: pid, ref: ref} = state.running[task_id]
        _ = Task.Supervisor.terminate_child(BDS.Tasks.TaskSupervisor, pid)

        next_state =
          state
          |> update_task(task_id, %{status: :cancelled, finished_at: DateTime.utc_now()})
          |> remove_running(task_id, ref)
          |> start_queued_tasks()
          |> schedule_finished_task_eviction()

        {:reply, :ok, next_state}

      Enum.any?(state.queue, fn {queued_id, _work} -> queued_id == task_id end) ->
        next_state =
          state
          |> update_task(task_id, %{status: :cancelled, finished_at: DateTime.utc_now()})
          |> Map.update!(:queue, fn queue ->
            Enum.reject(queue, fn {queued_id, _work} -> queued_id == task_id end)
          end)
          |> start_queued_tasks()
          |> schedule_finished_task_eviction()

        {:reply, :ok, next_state}

      state.tasks[task_id] == nil ->
        {:reply, {:error, :not_found}, state}

      true ->
        {:reply, {:error, :not_running}, state}
    end
  end

  def handle_call({:register_external_task, name, attrs}, _from, state) do
    task = new_task(name, :running, attrs) |> Map.put(:started_at, DateTime.utc_now())
    next_state = put_in(state, [:tasks, task.id], task)
    {:reply, {:ok, public_task(task)}, next_state}
  end

  def handle_call({:report_progress, task_id, value, message}, _from, state) do
    {:reply, :ok, maybe_report_progress(state, task_id, value, message)}
  end

  def handle_call({:complete_task, task_id}, _from, state) do
    next_state =
      state
      |> update_task(task_id, %{
        status: :completed,
        progress: 1.0,
        finished_at: DateTime.utc_now()
      })
      |> start_queued_tasks()
      |> schedule_finished_task_eviction()

    {:reply, :ok, next_state}
  end

  def handle_call({:fail_task, task_id, error_message}, _from, state) do
    next_state =
      state
      |> update_task(task_id, %{
        status: :failed,
        message: error_message,
        finished_at: DateTime.utc_now()
      })
      |> start_queued_tasks()
      |> schedule_finished_task_eviction()

    {:reply, :ok, next_state}
  end

  @impl true
  def handle_info({:task_progress, task_id, value, message}, state) do
    {:noreply, maybe_report_progress(state, task_id, value, message)}
  end

  def handle_info(:evict_finished_tasks, state) do
    {:noreply, prune_expired_finished_tasks(state)}
  end

  def handle_info({ref, result}, state) do
    case state.ref_to_task[ref] do
      nil ->
        {:noreply, state}

      task_id ->
        Process.demonitor(ref, [:flush])
        task = state.tasks[task_id]

        next_state =
          case task.status do
            :cancelled ->
              state

            _status ->
              attrs =
                case normalize_result(result) do
                  {:ok, value} ->
                    %{
                      status: :completed,
                      result: value,
                      progress: 1.0,
                      finished_at: DateTime.utc_now()
                    }

                  {:error, reason} ->
                    %{status: :failed, error: reason, finished_at: DateTime.utc_now()}
                end

              update_task(state, task_id, attrs)
          end
          |> remove_running(task_id, ref)
          |> start_queued_tasks()
          |> schedule_finished_task_eviction()

        {:noreply, next_state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case state.ref_to_task[ref] do
      nil ->
        {:noreply, state}

      task_id ->
        task = state.tasks[task_id]

        next_state =
          cond do
            task.status == :cancelled ->
              state

            reason == :normal ->
              state

            true ->
              update_task(state, task_id, %{
                status: :failed,
                error: reason,
                finished_at: DateTime.utc_now()
              })
          end
          |> remove_running(task_id, ref)
          |> start_queued_tasks()
          |> schedule_finished_task_eviction()

        {:noreply, next_state}
    end
  end

  defp start_task(state, task_id, work) do
    reporter = fn value, message ->
      send(__MODULE__, {:task_progress, task_id, value, message})
    end

    task =
      Task.Supervisor.async_nolink(BDS.Tasks.TaskSupervisor, fn ->
        work.(reporter)
      end)

    state
    |> update_task(task_id, %{status: :running, started_at: DateTime.utc_now()})
    |> put_in([:running, task_id], %{pid: task.pid, ref: task.ref})
    |> put_in([:ref_to_task, task.ref], task_id)
  end

  defp start_queued_tasks(state) do
    cond do
      map_size(state.running) >= max_concurrent() ->
        state

      state.queue == [] ->
        state

      true ->
        [{task_id, work} | remaining] = state.queue

        state
        |> Map.put(:queue, remaining)
        |> start_task(task_id, work)
        |> start_queued_tasks()
    end
  end

  defp remove_running(state, task_id, ref) do
    state
    |> update_in([:running], &Map.delete(&1, task_id))
    |> update_in([:ref_to_task], &Map.delete(&1, ref))
  end

  defp maybe_report_progress(state, task_id, value, message) do
    case state.tasks[task_id] do
      nil ->
        state

      task ->
        now_ms = System.monotonic_time(:millisecond)
        last_reported_at = Map.get(task, :last_reported_at)

        if is_nil(last_reported_at) or now_ms - last_reported_at >= progress_throttle_ms() or
             value == 1.0 do
          update_task(state, task_id, %{
            progress: value,
            message: message,
            last_reported_at: now_ms
          })
        else
          state
        end
    end
  end

  defp new_task(name, status, attrs) do
    %{
      id: "task-" <> Integer.to_string(System.unique_integer([:positive, :monotonic])),
      name: name,
      status: status,
      progress: nil,
      message: nil,
      group_id: attr(attrs, :group_id),
      group_name: attr(attrs, :group_name),
      created_at: DateTime.utc_now(),
      started_at: nil,
      finished_at: nil,
      result: nil,
      error: nil,
      last_reported_at: nil
    }
  end

  defp update_task(state, task_id, attrs) do
    update_in(state, [:tasks, task_id], fn
      nil -> nil
      task -> Map.merge(task, attrs)
    end)
  end

  defp schedule_finished_task_eviction(state) do
    Process.send_after(self(), :evict_finished_tasks, finished_task_ttl_ms())
    state
  end

  defp prune_expired_finished_tasks(state) do
    now = DateTime.utc_now()

    tasks =
      Map.reject(state.tasks, fn {_task_id, task} ->
        expired_finished_task?(task, now)
      end)

    %{state | tasks: tasks}
  end

  defp expired_finished_task?(%{status: status, finished_at: %DateTime{} = finished_at}, now)
       when status in [:completed, :failed, :cancelled] do
    DateTime.diff(now, finished_at, :millisecond) >= finished_task_ttl_ms()
  end

  defp expired_finished_task?(_task, _now), do: false

  defp public_task(nil), do: nil

  defp public_task(task) do
    task
    |> Map.drop([:last_reported_at])
    |> Map.update(:error, nil, &json_safe_value/1)
    |> Map.update(:result, nil, &json_safe_value/1)
  end

  defp build_status_snapshot(state) do
    active = active_tasks(state)
    tasks = active ++ recent_finished_tasks(state)

    %{
      active_count: length(active),
      running_count: Enum.count(active, &(&1.status == :running)),
      pending_count: Enum.count(active, &(&1.status == :pending)),
      running_task_message: running_task_message(active),
      running_task_overflow: running_task_overflow(active),
      tasks: Enum.map(tasks, &public_task/1)
    }
  end

  defp active_tasks(state) do
    state.tasks
    |> Map.values()
    |> Enum.filter(&(&1.status in [:running, :pending]))
    |> Enum.sort_by(&task_sort_key/1)
  end

  defp recent_finished_tasks(state) do
    state.tasks
    |> Map.values()
    |> Enum.filter(&(&1.status in [:completed, :failed, :cancelled]))
    |> Enum.sort_by(&DateTime.to_unix(&1.finished_at || &1.created_at, :microsecond), :desc)
    |> Enum.take(recent_finished_limit())
  end

  defp all_tasks(state) do
    state.tasks
    |> Map.values()
    |> Enum.sort_by(&DateTime.to_unix(&1.created_at, :microsecond), :desc)
  end

  defp running_tasks(state) do
    state.tasks
    |> Map.values()
    |> Enum.filter(&(&1.status == :running))
    |> Enum.sort_by(&task_sort_key/1)
  end

  defp task_sort_key(task) do
    {task_priority(task.status), task.started_at || task.created_at}
  end

  defp task_priority(:running), do: 0
  defp task_priority(:pending), do: 1

  defp running_task_message([]), do: nil

  defp running_task_message([task | _rest]) do
    cond do
      task.status == :pending -> "Queued: #{task.name}"
      is_binary(task.message) and task.message != "" -> "#{task.name}: #{task.message}"
      true -> task.name
    end
  end

  defp running_task_overflow([]), do: 0
  defp running_task_overflow(tasks), do: max(length(tasks) - 1, 0)

  defp normalize_result({:ok, _value} = result), do: result
  defp normalize_result({:error, _reason} = result), do: result
  defp normalize_result(value), do: {:ok, value}

  defp json_safe_value(value) when is_nil(value), do: nil
  defp json_safe_value(value) when is_binary(value), do: value
  defp json_safe_value(value) when is_boolean(value), do: value
  defp json_safe_value(value) when is_number(value), do: value
  defp json_safe_value(value) when is_atom(value), do: value

  defp json_safe_value(value) when is_list(value) do
    Enum.map(value, &json_safe_value/1)
  end

  defp json_safe_value(value) when is_struct(value), do: inspect(value)

  defp json_safe_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {json_safe_key(key), json_safe_value(item)} end)
  end

  defp json_safe_value(value) when is_tuple(value), do: inspect(value)
  defp json_safe_value(value), do: inspect(value)

  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key) when is_atom(key), do: key
  defp json_safe_key(key), do: inspect(key)

  defp max_concurrent do
    Application.get_env(:bds, :tasks, [])
    |> Keyword.get(:max_concurrent, @default_max_concurrent)
  end

  defp progress_throttle_ms do
    Application.get_env(:bds, :tasks, [])
    |> Keyword.get(:progress_throttle_ms, @default_progress_throttle_ms)
  end

  defp recent_finished_limit do
    Application.get_env(:bds, :tasks, [])
    |> Keyword.get(:recent_finished_limit, @default_recent_finished_limit)
  end

  defp finished_task_ttl_ms do
    Application.get_env(:bds, :tasks, [])
    |> Keyword.get(:finished_task_ttl_ms, @default_finished_task_ttl_ms)
  end

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
