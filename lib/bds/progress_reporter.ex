defmodule BDS.ProgressReporter do
  @moduledoc false

  @typedoc "A 2-arity progress callback `(progress :: float(), message :: String.t()) -> any()`."
  @type callback :: (float(), String.t() -> any()) | nil
  @type message_style :: :verb_label_parenthesized | :prefix_count | :verb_label_count | :label
  @type count_opts :: [
          {:verb, String.t() | nil},
          {:start_progress, float()},
          {:range, {float(), float()}},
          {:empty_message, String.t()},
          {:empty_suffix, String.t()},
          {:message_style, message_style()}
        ]

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

  @spec report_count_started(callback(), non_neg_integer(), String.t(), count_opts()) :: :ok
  def report_count_started(callback, total, label, opts \\ [])
  def report_count_started(nil, _total, _label, _opts), do: :ok

  def report_count_started(callback, 0, label, opts) do
    callback.(1.0, empty_message(label, opts))
    :ok
  end

  def report_count_started(callback, total, label, opts) do
    callback.(start_progress(opts), count_message(0, total, label, opts))
    :ok
  end

  @spec report_count_progress(
          callback(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          count_opts()
        ) :: :ok
  def report_count_progress(callback, current, total, label, opts \\ [])
  def report_count_progress(nil, _current, _total, _label, _opts), do: :ok
  def report_count_progress(_callback, _current, 0, _label, _opts), do: :ok

  def report_count_progress(callback, current, total, label, opts) do
    callback.(count_progress(current, total, opts), count_message(current, total, label, opts))
    :ok
  end

  @spec report_rebuild_started(callback(), non_neg_integer(), String.t()) :: :ok
  def report_rebuild_started(callback, total, label) do
    report_count_started(callback, total, label,
      verb: "Rebuilding",
      start_progress: 0.05,
      empty_suffix: "found",
      message_style: :verb_label_parenthesized
    )
  end

  @spec report_rebuild_progress(callback(), non_neg_integer(), non_neg_integer(), String.t()) ::
          :ok
  def report_rebuild_progress(callback, current, total, label) do
    report_count_progress(callback, current, total, label,
      verb: "Rebuilding",
      start_progress: 0.05,
      message_style: :verb_label_parenthesized
    )
  end

  @spec report_phase(callback(), float(), String.t()) :: :ok
  def report_phase(nil, _progress, _message), do: :ok

  def report_phase(callback, progress, message) do
    callback.(progress, message)
    :ok
  end

  defp count_progress(current, total, opts) do
    {start_value, end_value} = Keyword.get(opts, :range, {start_progress(opts), 1.0})
    start_value + (end_value - start_value) * (current / total)
  end

  defp start_progress(opts), do: Keyword.get(opts, :start_progress, 0.0)

  defp empty_message(label, opts) do
    case Keyword.fetch(opts, :empty_message) do
      {:ok, message} -> message
      :error -> "No #{label} #{Keyword.get(opts, :empty_suffix, "found")}"
    end
  end

  defp count_message(current, total, label, opts) do
    case Keyword.get(opts, :message_style, :verb_label_parenthesized) do
      :prefix_count -> "#{verb!(opts)} #{current}/#{total} #{label}"
      :verb_label_count -> "#{verb!(opts)} #{label} #{current}/#{total}"
      :label -> "#{label} (#{current}/#{total})"
      :verb_label_parenthesized -> "#{verb!(opts)} #{label} (#{current}/#{total})"
    end
  end

  defp verb!(opts), do: Keyword.get(opts, :verb, "Processing")
end
