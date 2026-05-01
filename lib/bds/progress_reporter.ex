defmodule BDS.ProgressReporter do
  @moduledoc false

  @typedoc "A 2-arity progress callback `(progress :: float(), message :: String.t()) -> any()`."
  @type callback :: (float(), String.t() -> any()) | nil

  @spec callback(keyword()) :: callback()
  def callback(opts) do
    case Keyword.get(opts, :on_progress) do
      callback when is_function(callback, 2) -> callback
      _other -> nil
    end
  end

  @spec scaled(callback(), float(), float()) :: callback()
  def scaled(nil, _start_value, _end_value), do: nil

  def scaled(report, start_value, end_value) when is_function(report, 2) do
    fn value, message ->
      scaled_value = start_value + (end_value - start_value) * value
      report.(scaled_value, message)
    end
  end

  @spec report_rebuild_started(callback(), non_neg_integer(), String.t()) :: :ok
  def report_rebuild_started(nil, _total, _label), do: :ok

  def report_rebuild_started(callback, 0, label) do
    callback.(1.0, "No #{label} found")
    :ok
  end

  def report_rebuild_started(callback, total, label) do
    callback.(0.05, "Rebuilding #{label} (0/#{total})")
    :ok
  end

  @spec report_rebuild_progress(callback(), non_neg_integer(), non_neg_integer(), String.t()) ::
          :ok
  def report_rebuild_progress(nil, _current, _total, _label), do: :ok
  def report_rebuild_progress(_callback, _current, 0, _label), do: :ok

  def report_rebuild_progress(callback, current, total, label) do
    callback.(0.05 + 0.95 * (current / total), "Rebuilding #{label} (#{current}/#{total})")
    :ok
  end

  @spec report_phase(callback(), float(), String.t()) :: :ok
  def report_phase(nil, _progress, _message), do: :ok

  def report_phase(callback, progress, message) do
    callback.(progress, message)
    :ok
  end
end
