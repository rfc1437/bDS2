defmodule BDS.Tasks do
  @moduledoc false

  use GenServer

  @type task_id :: String.t()
  @type task_attrs :: map()
  @type task_info :: map()
  @type status_snapshot :: map()
  @type progress_reporter :: (number(), String.t() | nil -> any())
  @type task_work :: (progress_reporter() -> term())

  @default_progress_throttle_ms 250
  @default_recent_finished_limit 10
  @default_finished_task_ttl_ms :timer.hours(1)
  @topic "tasks"

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec submit_task(String.t(), task_work()) :: {:ok, task_info()}
  @spec submit_task(String.t(), task_work(), task_attrs()) :: {:ok, task_info()}
  def submit_task(name, work, attrs \\ %{})
      when is_binary(name) and is_function(work, 1) and is_map(attrs) do
    GenServer.call(__MODULE__, {:submit_task, name, work, attrs})
  end

  @spec get_task(task_id()) :: task_info() | nil
  def get_task(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:get_task, task_id})
  end

  @spec status_snapshot() :: status_snapshot()
  def status_snapshot do
    GenServer.call(__MODULE__, :status_snapshot)
  end

  @spec list_tasks() :: [task_info()]
  def list_tasks do
    GenServer.call(__MODULE__, :list_tasks)
  end

  @spec list_running_tasks() :: [task_info()]
  def list_running_tasks do
    GenServer.call(__MODULE__, :list_running_tasks)
  end

  @spec clear_completed() :: :ok
  def clear_completed do
    GenServer.call(__MODULE__, :clear_completed)
  end

  @spec clear_finished() :: :ok
  def clear_finished do
    GenServer.call(__MODULE__, :clear_finished)
  end

  @spec cancel_task(task_id()) :: :ok | {:error, :not_found | :not_running}
  def cancel_task(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:cancel_task, task_id})
  end

  @impl true
  def init(_state) do
    {:ok,
     %{
       tasks: %{},
       queue: :queue.new(),
       running: %{},
       ref_to_task: %{},
       finished_task_eviction_timer: nil
     }}
  end

  @impl true
  def handle_call({:submit_task, name, work, attrs}, _from, state) do
    task = new_task(name, :pending, attrs)
    next_state = put_in(state, [:tasks, task.id], task)

    if map_size(next_state.running) < max_concurrent() do
      {:reply, {:ok, public_task(task)}, start_task(next_state, task.id, work)}
    else
      {:reply, {:ok, public_task(task)}, enqueue_task(next_state, task.id, work)}
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

        broadcast_terminal_task(next_state.tasks[task_id])

        {:reply, :ok, next_state}

      queued_task?(state.queue, task_id) ->
        next_state =
          state
          |> update_task(task_id, %{status: :cancelled, finished_at: DateTime.utc_now()})
          |> remove_queued_task(task_id)
          |> start_queued_tasks()
          |> schedule_finished_task_eviction()

        broadcast_terminal_task(next_state.tasks[task_id])

        {:reply, :ok, next_state}

      state.tasks[task_id] == nil ->
        {:reply, {:error, :not_found}, state}

      true ->
        {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_info({:task_progress, task_id, value, message}, state) do
    {:noreply, maybe_report_progress(state, task_id, value, message)}
  end

  def handle_info(:evict_finished_tasks, state) do
    next_state =
      state
      |> Map.put(:finished_task_eviction_timer, nil)
      |> prune_expired_finished_tasks()

    next_state =
      if any_finished_tasks?(next_state) do
        schedule_finished_task_eviction(next_state)
      else
        next_state
      end

    {:noreply, next_state}
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

        if task.status != :cancelled do
          broadcast_terminal_task(next_state.tasks[task_id])
        end

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

        if task.status != :cancelled and next_state.tasks[task_id].status == :failed do
          broadcast_terminal_task(next_state.tasks[task_id])
        end

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

      :queue.is_empty(state.queue) ->
        state

      true ->
        {{:value, {task_id, work}}, remaining} = :queue.out(state.queue)

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
      group_id: BDS.MapUtils.attr(attrs, :group_id),
      group_name: BDS.MapUtils.attr(attrs, :group_name),
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

  defp broadcast_terminal_task(nil), do: :ok

  defp broadcast_terminal_task(task) when task.status in [:completed, :failed, :cancelled] do
    Phoenix.PubSub.broadcast(BDS.PubSub, topic(), {:task_terminal, public_task(task)})
  end

  defp broadcast_terminal_task(_task), do: :ok

  defp schedule_finished_task_eviction(state) do
    if state.finished_task_eviction_timer do
      state
    else
      timer_ref = Process.send_after(self(), :evict_finished_tasks, finished_task_ttl_ms())
      %{state | finished_task_eviction_timer: timer_ref}
    end
  end

  defp prune_expired_finished_tasks(state) do
    now = DateTime.utc_now()

    tasks =
      Map.reject(state.tasks, fn {_task_id, task} ->
        expired_finished_task?(task, now)
      end)

    %{state | tasks: tasks}
  end

  defp enqueue_task(state, task_id, work) do
    %{state | queue: :queue.in({task_id, work}, state.queue)}
  end

  defp queued_task?(queue, task_id) do
    queue
    |> :queue.to_list()
    |> Enum.any?(fn {queued_id, _work} -> queued_id == task_id end)
  end

  defp remove_queued_task(state, task_id) do
    remaining_queue =
      state.queue
      |> :queue.to_list()
      |> Enum.reject(fn {queued_id, _work} -> queued_id == task_id end)
      |> :queue.from_list()

    %{state | queue: remaining_queue}
  end

  defp any_finished_tasks?(state) do
    Enum.any?(state.tasks, fn {_task_id, task} ->
      task.status in [:completed, :failed, :cancelled]
    end)
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
    |> Keyword.get(:max_concurrent, default_max_concurrent())
  end

  # The original TypeScript task manager hard-capped concurrency at 3 because it
  # ran on a single-threaded event loop. The BEAM schedules processes across
  # every CPU core, so the default tracks the number of online schedulers
  # (cores) instead — letting all render-site sections run in parallel. Override
  # with `config :bds, :tasks, max_concurrent: N`.
  defp default_max_concurrent, do: System.schedulers_online()

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

end
