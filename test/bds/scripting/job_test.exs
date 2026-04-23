defmodule BDS.Scripting.JobTest do
  use ExUnit.Case, async: false

  defmodule FakeRuntime do
    @behaviour BDS.Scripting.Runtime

    @impl true
    def validate(_source), do: :ok

    @impl true
    def execute(_source, _entrypoint, _args, opts) do
      if callback = Keyword.get(opts, :on_progress) do
        callback.(%{"phase" => "started", "current" => 1, "total" => 2})
      end

      Process.sleep(50)
      {:ok, "done"}
    end
  end

  defmodule BlockingRuntime do
    @behaviour BDS.Scripting.Runtime

    @impl true
    def validate(_source), do: :ok

    @impl true
    def execute(_source, _entrypoint, _args, opts) do
      if callback = Keyword.get(opts, :on_progress) do
        callback.(%{"phase" => "started", "current" => 1, "total" => 2})
      end

      receive do
        :never -> :ok
      end
    end
  end

  setup do
    original = Application.fetch_env!(:bds, :scripting)

    on_exit(fn ->
      Application.put_env(:bds, :scripting, original)
    end)

    :ok
  end

  test "runs long-lived script jobs asynchronously and tracks progress" do
    Application.put_env(:bds, :scripting,
      runtime: FakeRuntime,
      timeout: 300_000,
      max_reductions: 5_000_000,
      job_timeout: :infinity,
      job_max_reductions: :none
    )

    assert {:ok, job} = BDS.Scripting.start_job("irrelevant", "main")
    assert job.status in [:queued, :running]

    running_job = wait_for_job(job.id, &(&1.status == :running and &1.progress == %{"phase" => "started", "current" => 1, "total" => 2}))
    assert running_job.started_at != nil

    completed_job = wait_for_job(job.id, &(&1.status == :completed))
    assert completed_job.result == "done"
    assert completed_job.finished_at != nil
  end

  test "cancels managed script jobs" do
    Application.put_env(:bds, :scripting,
      runtime: BlockingRuntime,
      timeout: 300_000,
      max_reductions: 5_000_000,
      job_timeout: :infinity,
      job_max_reductions: :none
    )

    assert {:ok, job} = BDS.Scripting.start_job("irrelevant", "main")
    _running_job = wait_for_job(job.id, &(&1.status == :running))

    assert :ok = BDS.Scripting.cancel_job(job.id)

    cancelled_job = wait_for_job(job.id, &(&1.status == :cancelled))
    assert cancelled_job.finished_at != nil
  end

  defp wait_for_job(job_id, predicate, attempts \\ 50)

  defp wait_for_job(job_id, predicate, attempts) when attempts > 0 do
    job = BDS.Scripting.get_job(job_id)

    if predicate.(job) do
      job
    else
      Process.sleep(20)
      wait_for_job(job_id, predicate, attempts - 1)
    end
  end

  defp wait_for_job(_job_id, _predicate, 0) do
    flunk("job did not reach expected state")
  end
end
