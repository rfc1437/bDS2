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

  test "reports counted progress with prefix count message style" do
    parent = self()
    callback = fn progress, message -> send(parent, {progress, message}) end

    assert ProgressReporter.report_count_started(callback, 3, "pages",
             verb: "Processing",
             start_progress: 0.0,
             empty_suffix: "to process",
             message_style: :prefix_count
           ) == :ok

    assert ProgressReporter.report_count_progress(callback, 2, 4, "pages",
             verb: "Processing",
             start_progress: 0.0,
             message_style: :prefix_count
           ) == :ok

    assert_progress_received(0.0, "Processing 0/3 pages")
    assert_received {0.5, "Processing 2/4 pages"}
  end

  test "reports counted progress with label message style" do
    parent = self()
    callback = fn progress, message -> send(parent, {progress, message}) end

    assert ProgressReporter.report_count_started(callback, 5, "Repairing metadata",
             verb: nil,
             start_progress: 0.05,
             message_style: :label
           ) == :ok

    assert ProgressReporter.report_count_progress(callback, 3, 5, "Repairing metadata",
             verb: nil,
             start_progress: 0.05,
             message_style: :label
           ) == :ok

    assert_received {0.05, "Repairing metadata (0/5)"}
    assert_received {0.62, "Repairing metadata (3/5)"}
  end

  test "reports counted progress in a subrange" do
    parent = self()
    callback = fn progress, message -> send(parent, {progress, message}) end

    assert ProgressReporter.report_count_progress(callback, 1, 2, "sitemap URLs",
             verb: "Collecting",
             range: {0.30, 0.49},
             message_style: :prefix_count
           ) == :ok

    assert_received {0.395, "Collecting 1/2 sitemap URLs"}
  end

  test "reports counted progress with verb label count message style" do
    parent = self()
    callback = fn progress, message -> send(parent, {progress, message}) end

    assert ProgressReporter.report_count_progress(callback, 1, 2, "sitemap URLs...",
             verb: "Collecting",
             range: {0.30, 0.49},
             message_style: :verb_label_count
           ) == :ok

    assert_received {0.395, "Collecting sitemap URLs... 1/2"}
  end

  test "uses configurable empty counted messages" do
    parent = self()
    callback = fn progress, message -> send(parent, {progress, message}) end

    assert ProgressReporter.report_count_started(callback, 0, "posts",
             verb: "Reindexing",
             empty_suffix: "to reindex",
             message_style: :prefix_count
           ) == :ok

    assert_received {1.0, "No posts to reindex"}
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

  defp assert_progress_received(expected_progress, expected_message) do
    assert_received {progress, ^expected_message}
    assert_in_delta progress, expected_progress, 0.000001
  end
end
