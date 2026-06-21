defmodule BDS.Scripting.JobStore do
  @moduledoc false

  use Agent

  @spec start_link(term()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(fn -> %{jobs: %{}, runners: %{}} end, name: __MODULE__)
  end

  @spec put_job(map()) :: :ok
  def put_job(job) when is_map(job) do
    update_state(fn %{jobs: jobs} = state ->
      %{state | jobs: Map.put(jobs, job.id, job)}
    end)
  end

  @spec update_job(String.t(), map()) :: :ok
  def update_job(job_id, attrs) when is_binary(job_id) and is_map(attrs) do
    update_state(fn %{jobs: jobs} = state ->
      next_jobs =
        Map.update(jobs, job_id, nil, fn
          nil -> nil
          job -> Map.merge(job, attrs)
        end)

      %{state | jobs: next_jobs}
    end)
  end

  @spec attach_runner(String.t(), pid()) :: :ok
  def attach_runner(job_id, pid) when is_binary(job_id) and is_pid(pid) do
    update_state(fn %{runners: runners} = state ->
      %{state | runners: Map.put(runners, job_id, pid)}
    end)
  end

  @spec detach_runner(String.t()) :: :ok
  def detach_runner(job_id) when is_binary(job_id) do
    update_state(fn %{runners: runners} = state ->
      %{state | runners: Map.delete(runners, job_id)}
    end)
  end

  @spec fetch_job(String.t()) :: map() | nil
  def fetch_job(job_id) when is_binary(job_id) do
    get_state(&Map.get(&1.jobs, job_id))
  end

  @spec fetch_job!(String.t()) :: map()
  def fetch_job!(job_id) when is_binary(job_id) do
    case fetch_job(job_id) do
      nil -> raise KeyError, key: job_id, term: :jobs
      job -> job
    end
  end

  @spec runner_for(String.t()) :: pid() | nil
  def runner_for(job_id) when is_binary(job_id) do
    get_state(&Map.get(&1.runners, job_id))
  end

  defp get_state(fun), do: Agent.get(__MODULE__, fun)
  defp update_state(fun), do: Agent.update(__MODULE__, fun)
end
