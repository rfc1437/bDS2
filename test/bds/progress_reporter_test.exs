defmodule BDS.ProgressReporterTest do
  use ExUnit.Case, async: true

  alias BDS.ProgressReporter

  test "extracts only two-arity progress callbacks" do
    callback = fn _progress, _message -> :ok end

    assert ProgressReporter.callback(on_progress: callback) == callback
    assert ProgressReporter.callback(on_progress: fn _progress -> :ok end) == nil
    assert ProgressReporter.callback([]) == nil
  end

  test "reports rebuild start and progress messages" do
    parent = self()
    callback = fn progress, message -> send(parent, {progress, message}) end

    assert ProgressReporter.report_rebuild_started(callback, 3, "post files") == :ok
    assert ProgressReporter.report_rebuild_progress(callback, 2, 4, "post files") == :ok

    assert_received {0.05, "Rebuilding post files (0/3)"}
    assert_received {0.525, "Rebuilding post files (2/4)"}
  end

  test "reports empty rebuilds as complete" do
    parent = self()
    callback = fn progress, message -> send(parent, {progress, message}) end

    assert ProgressReporter.report_rebuild_started(callback, 0, "media files") == :ok

    assert_received {1.0, "No media files found"}
  end

  test "ignores nil callbacks and zero totals" do
    assert ProgressReporter.report_rebuild_started(nil, 3, "post files") == :ok
    assert ProgressReporter.report_rebuild_progress(nil, 1, 3, "post files") == :ok

    assert ProgressReporter.report_rebuild_progress(
             fn _, _ -> flunk("should not call") end,
             1,
             0,
             "post files"
           ) == :ok
  end

  test "scales nested progress reporters" do
    parent = self()
    callback = fn progress, message -> send(parent, {progress, message}) end
    scaled = ProgressReporter.scaled(callback, 0.25, 0.75)

    scaled.(0.5, "Halfway")

    assert_received {0.5, "Halfway"}
  end
end
