defmodule BDS.Maintenance.Progress do
  @moduledoc false

  def progress_callback(opts), do: BDS.ProgressReporter.callback(opts)

  def report_metadata_diff_phase(callback, current, total, label) do
    progress = if total <= 1, do: 0.0, else: (current - 1) / total
    BDS.ProgressReporter.report_phase(callback, progress, "#{label} (#{current}/#{total})")
  end

  def report_metadata_diff_complete(callback) do
    BDS.ProgressReporter.report_phase(callback, 1.0, "Metadata diff complete")
  end

  def report_started(callback, total, label) do
    BDS.ProgressReporter.report_count_started(callback, total, label,
      verb: nil,
      start_progress: 0.05,
      empty_message: label,
      message_style: :label
    )
  end

  def report_progress(callback, current, total, label) do
    BDS.ProgressReporter.report_count_progress(callback, current, total, label,
      verb: nil,
      start_progress: 0.05,
      message_style: :label
    )
  end
end
