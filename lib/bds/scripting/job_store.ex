defmodule BDS.Scripting.JobStore do
  @moduledoc false

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def put_job(job) when is_map(job) do
    GenServer.call(__MODULE__, {:put_job, job})
  end

  def update_job(job_id, attrs) when is_binary(job_id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:update_job, job_id, attrs})
  end

  def attach_runner(job_id, pid) when is_binary(job_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:attach_runner, job_id, pid})
  end

  def detach_runner(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:detach_runner, job_id})
  end

  def fetch_job(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:fetch_job, job_id})
  end

  def fetch_job!(job_id) when is_binary(job_id) do
    case fetch_job(job_id) do
      nil -> raise KeyError, key: job_id, term: :jobs
      job -> job
    end
  end

  def runner_for(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:runner_for, job_id})
  end

  @impl true
  def init(_state) do
    {:ok, %{jobs: %{}, runners: %{}}}
  end

  @impl true
  def handle_call({:put_job, %{id: job_id} = job}, _from, state) do
    next_state = put_in(state, [:jobs, job_id], job)
    {:reply, :ok, next_state}
  end

  def handle_call({:update_job, job_id, attrs}, _from, state) do
    next_state = update_in(state, [:jobs, job_id], fn
      nil -> nil
      job -> Map.merge(job, attrs)
    end)

    {:reply, :ok, next_state}
  end

  def handle_call({:attach_runner, job_id, pid}, _from, state) do
    next_state = put_in(state, [:runners, job_id], pid)
    {:reply, :ok, next_state}
  end

  def handle_call({:detach_runner, job_id}, _from, state) do
    next_state = update_in(state.runners, &Map.delete(&1, job_id))
    {:reply, :ok, %{state | runners: next_state}}
  end

  def handle_call({:fetch_job, job_id}, _from, state) do
    {:reply, Map.get(state.jobs, job_id), state}
  end

  def handle_call({:runner_for, job_id}, _from, state) do
    {:reply, Map.get(state.runners, job_id), state}
  end
end