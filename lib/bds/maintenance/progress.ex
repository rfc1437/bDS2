defmodule BDS.Maintenance.Progress do
  @moduledoc false

  def progress_callback(opts) do
    case Keyword.get(opts, :on_progress) do
      callback when is_function(callback, 2) -> callback
      _other -> nil
    end
  end

  def report_metadata_diff_phase(nil, _current, _total, _label), do: :ok

  def report_metadata_diff_phase(callback, current, total, label) do
    value = if total <= 1, do: 0.0, else: (current - 1) / total
    callback.(value, "#{label} (#{current}/#{total})")
    :ok
  end

  def report_metadata_diff_complete(nil), do: :ok

  def report_metadata_diff_complete(callback) do
    callback.(1.0, "Metadata diff complete")
    :ok
  end

  def report_started(nil, _total, _label), do: :ok

  def report_started(callback, 0, label) do
    callback.(1.0, label)
    :ok
  end

  def report_started(callback, total, label) do
    callback.(0.05, "#{label} (0/#{total})")
    :ok
  end

  def report_progress(nil, _current, _total, _label), do: :ok
  def report_progress(_callback, _current, 0, _label), do: :ok

  def report_progress(callback, current, total, label) do
    callback.(0.05 + 0.95 * (current / total), "#{label} (#{current}/#{total})")
    :ok
  end
end
