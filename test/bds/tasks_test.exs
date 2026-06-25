defmodule BDS.TasksTest do
  use ExUnit.Case, async: false

  setup do
    cleanup_task_server()

    original = Application.get_env(:bds, :tasks, [])
    Application.put_env(:bds, :tasks, max_concurrent: 3, progress_throttle_ms: 250)
    :ok = BDS.Tasks.clear_finished()

    on_exit(fn ->
      cleanup_task_server()
      Application.put_env(:bds, :tasks, original)
      _ = BDS.Tasks.clear_finished()
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

  test "cancel_task delivers shutdown so cleanup runs before freeing the slot" do
    Application.put_env(:bds, :tasks, max_concurrent: 1, progress_throttle_ms: 250)

    runner = self()

    cleanup_work = fn _report ->
      Process.flag(:trap_exit, true)
      send(runner, {:started, "cleanup", self()})

      receive do
        {:EXIT, _from, :shutdown} ->
          send(runner, :cleanup_ran)
          {:ok, :cancelled}
      end
    end

    queued_work = fn _report ->
      send(runner, {:started, "queued", self()})
      {:ok, :queued_completed}
    end

    assert {:ok, running} = BDS.Tasks.submit_task("cleanup", cleanup_work)
    assert {:ok, queued} = BDS.Tasks.submit_task("queued", queued_work)

    assert {"cleanup", _pid} = receive_started()
    assert BDS.Tasks.get_task(queued.id).status == :pending

    assert :ok = BDS.Tasks.cancel_task(running.id)
    assert_receive :cleanup_ran, 1_000
    assert wait_for_task(running.id, &(&1.status == :cancelled)).status == :cancelled

    assert {"queued", _pid} = receive_started()
    assert wait_for_task(queued.id, &(&1.status == :completed)).result == :queued_completed
  end

  test "progress reports within 250ms throttle window are silently dropped" do
    runner = self()

    assert {:ok, task} =
             BDS.Tasks.submit_task("fast progress", fn report ->
               send(runner, {:started, "fast progress", self()})
               report.(0.25, "quarter")
               report.(0.5, "half")

               receive do
                 :release -> {:ok, :done}
               end
             end)

    {"fast progress", worker_pid} = receive_started()

    assert wait_for_task(task.id, &(&1.progress == 0.25)).progress == 0.25

    # The 250ms throttle has not elapsed, so progress stays at 0.25.
    assert wait_for_task(task.id, &(&1.progress == 0.25)).progress == 0.25

    send(worker_pid, :release)
    assert wait_for_task(task.id, &(&1.status == :completed)).status == :completed
  end

  test "progress report with value 1.0 bypasses the throttle" do
    runner = self()

    assert {:ok, task} =
             BDS.Tasks.submit_task("completion progress", fn report ->
               send(runner, {:started, "completion progress", self()})
               report.(0.25, "quarter")
               report.(1.0, "done")

               receive do
                 :release -> {:ok, :done}
               end
             end)

    {"completion progress", worker_pid} = receive_started()

    # A completion report (1.0) must go through even if throttled.
    assert wait_for_task(task.id, &(&1.progress == 1.0)).progress == 1.0
    assert wait_for_task(task.id, &(&1.message == "done")).message == "done"

    send(worker_pid, :release)
    assert wait_for_task(task.id, &(&1.status == :completed)).status == :completed
  end

  test "submitted tasks are registered as running and can report progress and complete" do
    assert {:ok, task} =
             BDS.Tasks.submit_task(
               "preview build",
               fn report ->
                 report.(0.5, "halfway")

                 receive do
                   :release -> {:ok, :done}
                 end
               end,
               %{
               group_id: "generation",
               group_name: "Generation"
               }
             )

    assert task.status == :pending
    assert task.group_id == "generation"
    assert task.group_name == "Generation"

    progressed = wait_for_task(task.id, &(&1.progress == 0.5 and &1.message == "halfway"))
    assert progressed.status == :running

    task_state = :sys.get_state(BDS.Tasks)
    %{pid: worker_pid} = task_state.running[task.id]
    send(worker_pid, :release)

    assert wait_for_task(task.id, &(&1.status == :completed and &1.progress == 1.0)).status ==
             :completed
  end

  test "status_snapshot exposes active task details for the desktop shell" do
    runner = self()

    assert {:ok, first} =
             BDS.Tasks.submit_task(
               "preview build",
               fn report ->
                 send(runner, {:started, "preview build", self()})
                 report.(0.5, "halfway")

                 receive do
                   :release -> {:ok, :done}
                 end
               end,
               %{group_id: "generation", group_name: "Generation"}
             )

    assert {:ok, second} =
             BDS.Tasks.submit_task(
               "reindex text",
               fn _report ->
                 send(runner, {:started, "reindex text", self()})

                 receive do
                   :release -> {:ok, :done}
                 end
               end,
               %{group_id: "search", group_name: "Search"}
             )

    on_exit(fn ->
      task_state = :sys.get_state(BDS.Tasks)

      Enum.each([first.id, second.id], fn task_id ->
        case task_state.running[task_id] do
          %{pid: pid} -> send(pid, :release)
          nil -> :ok
        end
      end)
    end)

    _ = receive_started()
    _ = receive_started()

    snapshot = BDS.Tasks.status_snapshot()

    assert snapshot.active_count == 2
    assert snapshot.running_task_overflow == 1
    assert snapshot.running_task_message == "preview build: halfway"

    assert [
             %{id: first_id, status: :running, progress: 0.5, group_name: "Generation"},
             %{id: second_id, status: :running}
           ] =
             snapshot.tasks

    assert first_id == first.id
    assert second_id == second.id
  end

  test "status_snapshot retains recently finished tasks for desktop shell completion state" do
    assert {:ok, task} =
             BDS.Tasks.submit_task(
               "rebuild database",
               fn report ->
                 report.(0.4, "rebuilding")
                 {:ok, %{counts: %{posts: 2}}}
               end,
               %{group_id: "maintenance", group_name: "Maintenance"}
             )

    completed =
      wait_for_task(task.id, &(&1.status == :completed and &1.result == %{counts: %{posts: 2}}))

    snapshot = BDS.Tasks.status_snapshot()

    assert snapshot.active_count == 0
    assert snapshot.running_count == 0
    assert snapshot.pending_count == 0
    assert snapshot.running_task_message == nil

    assert Enum.any?(snapshot.tasks, fn item ->
             item.id == completed.id and item.status == :completed and
               item.result == %{counts: %{posts: 2}}
           end)
  end

  test "finished tasks are evicted after the configured TTL" do
    Application.put_env(:bds, :tasks,
      max_concurrent: 3,
      progress_throttle_ms: 250,
      finished_task_ttl_ms: 1
    )

    runner = self()

    assert {:ok, task} = BDS.Tasks.submit_task("short lived", fn _report -> {:ok, :done} end)

    assert {:ok, running} =
             BDS.Tasks.submit_task("still running", fn _report ->
               send(runner, {:started, "still running", self()})

               receive do
                 :release -> {:ok, :done}
               end
             end)

    {"still running", worker_pid} = receive_started()

    on_exit(fn -> send(worker_pid, :release) end)

    assert wait_for_task(task.id, &(&1.status == :completed)).status == :completed

    Process.sleep(20)

    task_ids = BDS.Tasks.list_tasks() |> Enum.map(& &1.id)

    refute task.id in task_ids
    assert running.id in task_ids
  end

  test "finished task eviction uses a single live timer" do
    Application.put_env(:bds, :tasks,
      max_concurrent: 3,
      progress_throttle_ms: 250,
      finished_task_ttl_ms: 50
    )

    assert {:ok, first} = BDS.Tasks.submit_task("first finished", fn _report -> {:ok, :done} end)
    assert {:ok, second} = BDS.Tasks.submit_task("second finished", fn _report -> {:ok, :done} end)

    assert wait_for_task(first.id, &(&1.status == :completed)).status == :completed
    first_timer = :sys.get_state(BDS.Tasks).finished_task_eviction_timer
    assert is_reference(first_timer)
    assert is_integer(Process.read_timer(first_timer))

    assert wait_for_task(second.id, &(&1.status == :completed)).status == :completed
    second_timer = :sys.get_state(BDS.Tasks).finished_task_eviction_timer

    assert second_timer == first_timer
    assert is_integer(Process.read_timer(second_timer))
  end

  test "task queue implementation avoids list append churn" do
    source = File.read!("lib/bds/tasks.ex")

    assert String.contains?(source, ":queue"), "tasks queue should use :queue"

    refute String.contains?(source, "queue ++"),
           "tasks queue should not append with ++"
  end

  test "terminal task states are broadcast on PubSub" do
    Phoenix.PubSub.subscribe(BDS.PubSub, BDS.Tasks.topic())

    assert {:ok, completed} =
             BDS.Tasks.submit_task("broadcast completion", fn _report -> {:ok, :done} end,
               %{group_id: "broadcast-group", group_name: "Maintenance"}
             )

    assert_receive {:task_terminal, task_event}, 1_000
    assert task_event.id == completed.id
    assert task_event.group_id == "broadcast-group"
    assert task_event.status == :completed
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

  defp cleanup_task_server do
    BDS.Tasks.list_tasks()
    |> Enum.filter(&(&1.status in [:pending, :running]))
    |> Enum.each(fn task ->
      _ = BDS.Tasks.cancel_task(task.id)
    end)

    wait_until(fn ->
      BDS.Tasks.list_tasks()
      |> Enum.all?(&(&1.status not in [:pending, :running]))
    end)

    :ok = BDS.Tasks.clear_finished()
  end

  defp wait_until(predicate, attempts \\ 100)

  defp wait_until(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      wait_until(predicate, attempts - 1)
    end
  end

  defp wait_until(_predicate, 0) do
    flunk("condition was not met")
  end

end
