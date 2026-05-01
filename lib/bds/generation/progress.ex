defmodule BDS.Generation.Progress do
  @moduledoc false

  @typedoc "A 2-arity progress callback `(progress :: float(), message :: String.t()) -> any()`."
  @type callback :: (float(), String.t() -> any()) | nil

  @typedoc "A 3-arity stage callback `(stage :: atom(), current :: integer(), total :: integer()) -> any()`."
  @type stage_callback :: (atom(), integer(), integer() -> any()) | nil

  @doc "Extract the `:on_progress` callback from a keyword list of options."
  @spec callback(keyword()) :: callback()
  def callback(opts) do
    case Keyword.get(opts, :on_progress) do
      cb when is_function(cb, 2) -> cb
      _other -> nil
    end
  end

  @spec report_generation_started(callback(), non_neg_integer(), String.t()) :: :ok
  def report_generation_started(nil, _total, _label), do: :ok

  def report_generation_started(callback, 0, label) do
    callback.(1.0, "No #{label} to process")
    :ok
  end

  def report_generation_started(callback, total, label) do
    callback.(0.0, "Processing 0/#{total} #{label}")
    :ok
  end

  @spec report_generation_progress(callback(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  def report_generation_progress(nil, _current, _total, _label), do: :ok
  def report_generation_progress(_callback, _current, 0, _label), do: :ok

  def report_generation_progress(callback, current, total, label) do
    callback.(current / total, "Processing #{current}/#{total} #{label}")
    :ok
  end

  @spec report_validation_progress(callback(), float(), String.t()) :: :ok
  def report_validation_progress(nil, _progress, _message), do: :ok

  def report_validation_progress(callback, progress, message) do
    callback.(progress, message)
    :ok
  end

  @spec report_validation_snapshot_progress(callback(), atom(), non_neg_integer(), integer()) :: :ok
  def report_validation_snapshot_progress(nil, _stage, _current, _total), do: :ok

  def report_validation_snapshot_progress(_callback, _stage, _current, total)
      when total <= 0,
      do: :ok

  def report_validation_snapshot_progress(callback, :posts, current, total) do
    progress = min(0.18, current / total * 0.18)
    callback.(progress, "Collecting sitemap URLs... #{current}/#{total}")
    :ok
  end

  def report_validation_snapshot_progress(callback, :translations, current, total) do
    progress = 0.18 + min(0.12, current / total * 0.12)
    callback.(progress, "Collecting sitemap URLs... #{current}/#{total}")
    :ok
  end

  @spec report_validation_collection_progress(callback(), non_neg_integer(), integer()) :: :ok
  def report_validation_collection_progress(nil, _current, _total), do: :ok
  def report_validation_collection_progress(_callback, _current, total) when total <= 0, do: :ok

  def report_validation_collection_progress(callback, current, total) do
    progress = min(0.49, 0.30 + current / total * 0.19)
    callback.(progress, "Collecting sitemap URLs... #{current}/#{total}")
    :ok
  end

  @spec report_snapshot_stage_progress(stage_callback(), atom(), non_neg_integer(), integer()) :: :ok
  def report_snapshot_stage_progress(nil, _stage, _current, _total), do: :ok
  def report_snapshot_stage_progress(_callback, _stage, _current, total) when total <= 0, do: :ok

  def report_snapshot_stage_progress(callback, stage, current, total) do
    callback.(stage, current, total)
    :ok
  end

  @spec report_validation_compare_progress(callback(), non_neg_integer(), integer()) :: :ok
  def report_validation_compare_progress(nil, _current, _total), do: :ok
  def report_validation_compare_progress(_callback, _current, total) when total <= 0, do: :ok

  def report_validation_compare_progress(callback, current, total) do
    progress = min(0.99, 0.5 + current / total * 0.49)
    callback.(progress, "Comparing sitemap to html pages... #{current}/#{total}")
    :ok
  end
end
