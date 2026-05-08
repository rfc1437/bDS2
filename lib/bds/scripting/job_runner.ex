defmodule BDS.Scripting.JobRunner do
  @moduledoc false

  use GenServer, restart: :temporary

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def cancel(pid) when is_pid(pid) do
    GenServer.call(pid, :cancel)
  end

  @impl true
  def init(opts) do
    state = %{
      job_id: Keyword.fetch!(opts, :job_id),
      runtime: Keyword.fetch!(opts, :runtime),
      source: Keyword.fetch!(opts, :source),
      entrypoint: Keyword.fetch!(opts, :entrypoint),
      args: Keyword.get(opts, :args, []),
      opts: Keyword.get(opts, :opts, []),
      task_pid: nil,
      task_ref: nil,
      completed?: false,
      cancelled?: false
    }

    Process.flag(:trap_exit, true)
    {:ok, state, {:continue, :attach_and_start}}
  end

  @impl true
  def handle_continue(:attach_and_start, state) do
    :ok = BDS.Scripting.JobStore.attach_runner(state.job_id, self())
    {:noreply, state, {:continue, :start_job}}
  end

  @impl true
  def handle_continue(:start_job, state) do
    :ok =
      BDS.Scripting.JobStore.update_job(state.job_id, %{
        status: :running,
        started_at: DateTime.utc_now()
      })

    runner = self()

    task =
      Task.Supervisor.async_nolink(BDS.Scripting.TaskSupervisor, fn ->
        state.runtime.execute(
          state.source,
          state.entrypoint,
          state.args,
          Keyword.put(state.opts, :on_progress, fn event ->
            send(runner, {:job_progress, event})
          end)
        )
      end)

    {:noreply, %{state | task_pid: task.pid, task_ref: task.ref}}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    if is_pid(state.task_pid) do
      Process.exit(state.task_pid, :kill)
    end

    :ok =
      BDS.Scripting.JobStore.update_job(state.job_id, %{
        status: :cancelled,
        finished_at: DateTime.utc_now()
      })

    {:stop, :normal, :ok, %{state | cancelled?: true}}
  end

  @impl true
  def handle_info({:job_progress, progress}, state) do
    :ok = BDS.Scripting.JobStore.update_job(state.job_id, %{progress: progress})
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    unless state.cancelled? do
      attrs =
        case result do
          {:ok, value} ->
            %{status: :completed, result: value, finished_at: DateTime.utc_now()}

          {:error, reason} ->
            %{status: :failed, error: reason, finished_at: DateTime.utc_now()}
        end

      :ok = BDS.Scripting.JobStore.update_job(state.job_id, attrs)
    end

    {:stop, :normal, %{state | completed?: true}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    cond do
      state.completed? or state.cancelled? ->
        {:stop, :normal, state}

      reason == :normal ->
        {:noreply, state}

      true ->
        :ok =
          BDS.Scripting.JobStore.update_job(state.job_id, %{
            status: :failed,
            error: reason,
            finished_at: DateTime.utc_now()
          })

        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    try do
      BDS.Scripting.JobStore.detach_runner(state.job_id)
    catch
      :exit, _ -> :ok
    end
  end
end
