defmodule BDS.TasksTest do
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:bds, :tasks, [])
    Application.put_env(:bds, :tasks, max_concurrent: 3, progress_throttle_ms: 250)

    on_exit(fn ->
      Application.put_env(:bds, :tasks, original)
    end)

    :ok
  end

  test "submitted tasks respect max concurrency and FIFO queue order" do
    runner = self()

    work = fn name ->
      fn _report ->
        send(runner, {:started, name, self()})

        receive do
          {:release, ^name} -> :ok
        end

        {:ok, name}
      end
    end

    assert {:ok, first} = BDS.Tasks.submit_task("first", work.("first"))
    assert {:ok, second} = BDS.Tasks.submit_task("second", work.("second"))
    assert {:ok, third} = BDS.Tasks.submit_task("third", work.("third"))
    assert {:ok, fourth} = BDS.Tasks.submit_task("fourth", work.("fourth"))

    started = for _ <- 1..3, do: receive_started()
    assert Enum.sort(Enum.map(started, &elem(&1, 0))) == ["first", "second", "third"]

    started_by_name = Map.new(started, fn {name, pid} -> {name, pid} end)

    assert BDS.Tasks.get_task(first.id).status == :running
    assert BDS.Tasks.get_task(second.id).status == :running
    assert BDS.Tasks.get_task(third.id).status == :running
    assert BDS.Tasks.get_task(fourth.id).status == :pending

    send(started_by_name["first"], {:release, "first"})

    assert wait_for_task(first.id, &(&1.status == :completed)).result == "first"
    {"fourth", fourth_pid} = receive_started()
    assert wait_for_task(fourth.id, &(&1.status == :running)).status == :running

    send(started_by_name["second"], {:release, "second"})
    send(started_by_name["third"], {:release, "third"})
    send(fourth_pid, {:release, "fourth"})

    assert wait_for_task(second.id, &(&1.status == :completed)).result == "second"
    assert wait_for_task(third.id, &(&1.status == :completed)).result == "third"
    assert wait_for_task(fourth.id, &(&1.status == :completed)).result == "fourth"
  end

  test "cancel_task cancels pending and running tasks" do
    runner = self()

    blocking = fn name ->
      fn _report ->
        send(runner, {:started, name, self()})

        receive do
          {:release, ^name} -> :ok
        end

        {:ok, name}
      end
    end

    assert {:ok, first} = BDS.Tasks.submit_task("one", blocking.("one"))
    assert {:ok, second} = BDS.Tasks.submit_task("two", blocking.("two"))
    assert {:ok, third} = BDS.Tasks.submit_task("three", blocking.("three"))
    assert {:ok, pending} = BDS.Tasks.submit_task("four", blocking.("four"))

    started = for _ <- 1..3, do: receive_started()
    started_by_name = Map.new(started, fn {name, pid} -> {name, pid} end)

    assert :ok = BDS.Tasks.cancel_task(pending.id)
    assert wait_for_task(pending.id, &(&1.status == :cancelled)).status == :cancelled

    assert :ok = BDS.Tasks.cancel_task(first.id)
    assert wait_for_task(first.id, &(&1.status == :cancelled)).status == :cancelled

    send(started_by_name["two"], {:release, "two"})
    send(started_by_name["three"], {:release, "three"})

    assert wait_for_task(second.id, &(&1.status == :completed)).status == :completed
    assert wait_for_task(third.id, &(&1.status == :completed)).status == :completed
  end

  test "external tasks are registered as running and can report progress and complete" do
    assert {:ok, task} =
             BDS.Tasks.register_external_task("preview build", %{
               group_id: "generation",
               group_name: "Generation"
             })

    assert task.status == :running
    assert task.group_id == "generation"
    assert task.group_name == "Generation"

    assert :ok = BDS.Tasks.report_progress(task.id, 0.5, "halfway")

    progressed = wait_for_task(task.id, &(&1.progress == 0.5 and &1.message == "halfway"))
    assert progressed.status == :running

    assert :ok = BDS.Tasks.complete_task(task.id)

    assert wait_for_task(task.id, &(&1.status == :completed and &1.progress == 1.0)).status ==
             :completed
  end

  defp receive_started do
    receive do
      {:started, name, pid} -> {name, pid}
    after
      1_000 -> flunk("task did not start")
    end
  end

  defp wait_for_task(task_id, predicate, attempts \\ 100)

  defp wait_for_task(task_id, predicate, attempts) when attempts > 0 do
    task = BDS.Tasks.get_task(task_id)

    if predicate.(task) do
      task
    else
      Process.sleep(20)
      wait_for_task(task_id, predicate, attempts - 1)
    end
  end

  defp wait_for_task(_task_id, _predicate, 0) do
    flunk("task did not reach expected state")
  end
end
