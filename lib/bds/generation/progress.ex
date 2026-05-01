defmodule BDS.Generation.Progress do
  @moduledoc false

  @typedoc "A 2-arity progress callback `(progress :: float(), message :: String.t()) -> any()`."
  @type callback :: (float(), String.t() -> any()) | nil

  @typedoc "A 3-arity stage callback `(stage :: atom(), current :: integer(), total :: integer()) -> any()`."
  @type stage_callback :: (atom(), integer(), integer() -> any()) | nil

  @doc "Extract the `:on_progress` callback from a keyword list of options."
  @spec callback(keyword()) :: callback()
  def callback(opts), do: BDS.ProgressReporter.callback(opts)

  @spec report_generation_started(callback(), non_neg_integer(), String.t()) :: :ok
  def report_generation_started(callback, total, label) do
    BDS.ProgressReporter.report_count_started(callback, total, label,
      verb: "Processing",
      start_progress: 0.0,
      empty_suffix: "to process",
      message_style: :prefix_count
    )
  end

  @spec report_generation_progress(callback(), non_neg_integer(), non_neg_integer(), String.t()) ::
          :ok
  def report_generation_progress(callback, current, total, label) do
    BDS.ProgressReporter.report_count_progress(callback, current, total, label,
      verb: "Processing",
      start_progress: 0.0,
      message_style: :prefix_count
    )
  end

  @spec report_validation_progress(callback(), float(), String.t()) :: :ok
  def report_validation_progress(callback, progress, message),
    do: BDS.ProgressReporter.report_phase(callback, progress, message)

  @spec report_validation_snapshot_progress(callback(), atom(), non_neg_integer(), integer()) ::
          :ok
  def report_validation_snapshot_progress(callback, :posts, current, total) do
    BDS.ProgressReporter.report_count_progress(callback, current, total, "sitemap URLs...",
      verb: "Collecting",
      range: {0.0, 0.18},
      message_style: :verb_label_count
    )
  end

  def report_validation_snapshot_progress(callback, :translations, current, total) do
    BDS.ProgressReporter.report_count_progress(callback, current, total, "sitemap URLs...",
      verb: "Collecting",
      range: {0.18, 0.30},
      message_style: :verb_label_count
    )
  end

  @spec report_validation_collection_progress(callback(), non_neg_integer(), integer()) :: :ok
  def report_validation_collection_progress(callback, current, total) do
    BDS.ProgressReporter.report_count_progress(callback, current, total, "sitemap URLs...",
      verb: "Collecting",
      range: {0.30, 0.49},
      message_style: :verb_label_count
    )
  end

  @spec report_snapshot_stage_progress(stage_callback(), atom(), non_neg_integer(), integer()) ::
          :ok
  def report_snapshot_stage_progress(nil, _stage, _current, _total), do: :ok
  def report_snapshot_stage_progress(_callback, _stage, _current, total) when total <= 0, do: :ok

  def report_snapshot_stage_progress(callback, stage, current, total) do
    callback.(stage, current, total)
    :ok
  end

  @spec report_validation_compare_progress(callback(), non_neg_integer(), integer()) :: :ok
  def report_validation_compare_progress(callback, current, total) do
    BDS.ProgressReporter.report_count_progress(
      callback,
      current,
      total,
      "sitemap to html pages...",
      verb: "Comparing",
      range: {0.5, 0.99},
      message_style: :verb_label_count
    )
  end
end
