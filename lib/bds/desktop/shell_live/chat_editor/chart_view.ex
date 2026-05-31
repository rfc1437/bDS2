defmodule BDS.Desktop.ShellLive.ChatEditor.ChartView do
  @moduledoc """
  Pure geometry/view helpers for rendering a2ui chart surfaces.

  Mirrors the behaviour of the legacy bDS `A2UIChart` React component so the
  Elixir rewrite supports the same chart types (`bar`, `stacked-bar`, `line`,
  `area`, `pie`, `donut`, `heatmap`) with the same visual output. Each function
  returns plain maps/lists that a HEEx template can iterate over; no markup is
  produced here so the geometry stays unit-testable.

  Series entries are expected to be maps with `:label`, `:value` and an optional
  list of `:segments` (each a map with `:label` and `:value`).
  """

  # Matches the legacy bDS SEGMENT_COLORS palette.
  @palette ["#75beff", "#89d185", "#d18616", "#f14c4c", "#b180d7", "#e2e210"]

  # Line/area chart geometry (viewBox units), matching the legacy component.
  @line_width 300
  @line_height 140
  @pad_top 8
  @pad_right 12
  @pad_bottom 24
  @pad_left 40

  @doc "Returns the colour for the series/segment at `index` (cycles the palette)."
  @spec color(integer()) :: String.t()
  def color(index), do: Enum.at(@palette, rem(index, length(@palette)))

  @doc """
  Pie/donut geometry: SVG slices, a legend and the running total.
  """
  @spec pie([map()]) :: map()
  def pie(series) do
    total = series |> Enum.map(& &1.value) |> Enum.sum()
    center = 70
    radius = 56

    {slices, _angle} =
      if total > 0 do
        series
        |> Enum.with_index()
        |> Enum.map_reduce(0.0, fn {entry, i}, current ->
          slice_angle = entry.value / total * 360
          end_angle = current + slice_angle

          slice =
            if slice_angle >= 359.99 do
              %{full_circle: true, d: nil, color: color(i), label: entry.label, value: entry.value}
            else
              %{
                full_circle: false,
                d: describe_slice(center, radius, current, end_angle),
                color: color(i),
                label: entry.label,
                value: entry.value
              }
            end

          {slice, end_angle}
        end)
      else
        {[], 0.0}
      end

    %{
      size: 140,
      center: center,
      radius: radius,
      donut_inner: radius * 0.58,
      total: total,
      slices: slices,
      legend: legend(series)
    }
  end

  @doc """
  Line/area geometry: gridlines + Y labels, the polyline points, an optional
  area polygon, the data dots and the X-axis labels.
  """
  @spec line([map()], boolean()) :: map()
  def line(series, area?) do
    plot_width = @line_width - @pad_left - @pad_right
    plot_height = @line_height - @pad_top - @pad_bottom
    max_value = Enum.max([0 | Enum.map(series, & &1.value)])
    ticks = y_ticks(max_value)
    y_max = List.last(ticks)
    len = length(series)
    x_step = if len > 1, do: plot_width / (len - 1), else: 0.0

    points =
      series
      |> Enum.with_index()
      |> Enum.map(fn {entry, i} ->
        x = @pad_left + if(len > 1, do: i * x_step, else: plot_width / 2)
        y = @pad_top + if(y_max > 0, do: (1 - entry.value / y_max) * plot_height, else: plot_height)
        %{x: x, y: y, label: entry.label, value: entry.value}
      end)

    polyline = Enum.map_join(points, " ", fn p -> "#{fmt(p.x)},#{fmt(p.y)}" end)
    baseline = @pad_top + plot_height

    area_points =
      case {area?, points} do
        {true, [_ | _]} ->
          first = List.first(points)
          last = List.last(points)
          "#{fmt(first.x)},#{fmt(baseline)} #{polyline} #{fmt(last.x)},#{fmt(baseline)}"

        _ ->
          ""
      end

    grid =
      Enum.map(ticks, fn tick ->
        y = @pad_top + if(y_max > 0, do: (1 - tick / y_max) * plot_height, else: plot_height)

        %{
          y: fmt(y),
          x1: fmt(@pad_left),
          x2: fmt(@pad_left + plot_width),
          label: fmt(tick),
          label_x: fmt(@pad_left - 4)
        }
      end)

    %{
      view_box: "0 0 #{@line_width} #{@line_height}",
      area?: area?,
      area_points: area_points,
      polyline: polyline,
      grid: grid,
      dots: Enum.map(points, fn p -> %{x: fmt(p.x), y: fmt(p.y), label: p.label, value: p.value} end),
      x_labels:
        Enum.map(points, fn p -> %{x: fmt(p.x), y: fmt(@line_height - 4), label: p.label} end)
    }
  end

  @doc """
  Heatmap grid: column labels plus rows of colour-scaled cells. Each series
  entry is a row and each of its segments is a column.
  """
  @spec heatmap([map()]) :: map()
  def heatmap(series) do
    rows_src = Enum.filter(series, &(&1.segments != []))
    columns = rows_src |> Enum.flat_map(fn e -> Enum.map(e.segments, & &1.label) end) |> Enum.uniq()

    global_max =
      case Enum.flat_map(rows_src, fn e -> Enum.map(e.segments, & &1.value) end) do
        [] -> 0
        values -> Enum.max(values)
      end

    rows =
      Enum.map(rows_src, fn entry ->
        seg_map = Map.new(entry.segments, fn s -> {s.label, s.value} end)

        cells =
          Enum.map(columns, fn col ->
            value = Map.get(seg_map, col, 0)
            alpha = if global_max > 0, do: value / global_max, else: 0.0
            {bg, fg} = cell_colors(alpha)
            %{value: value, bg: bg, fg: fg}
          end)

        %{label: entry.label, cells: cells}
      end)

    %{columns: columns, column_count: length(columns), rows: rows}
  end

  @doc """
  Stacked-bar geometry: each row's segments with widths and colours, plus a
  legend of the unique segment labels.
  """
  @spec stacked([map()]) :: map()
  def stacked(series) do
    seg_labels =
      series |> Enum.flat_map(fn e -> Enum.map(e.segments, & &1.label) end) |> Enum.uniq()

    totals =
      Enum.map(series, fn e ->
        if e.segments == [], do: e.value, else: Enum.sum(Enum.map(e.segments, & &1.value))
      end)

    max_total = Enum.max([0 | totals])

    rows =
      series
      |> Enum.zip(totals)
      |> Enum.map(fn {entry, total} ->
        segments =
          Enum.map(entry.segments, fn s ->
            width = if max_total > 0, do: s.value / max_total * 100, else: 0.0

            %{
              label: s.label,
              value: s.value,
              width: fmt(width),
              color: color(Enum.find_index(seg_labels, &(&1 == s.label)) || 0)
            }
          end)

        %{label: entry.label, total: total, segments: segments}
      end)

    legend = seg_labels |> Enum.with_index() |> Enum.map(fn {l, i} -> %{label: l, color: color(i)} end)

    %{rows: rows, legend: legend, max_total: max_total}
  end

  @doc """
  Nice, rounded Y-axis tick values for `max_value`. Always starts at 0 and ends
  at or above `max_value`.
  """
  @spec y_ticks(number(), pos_integer()) :: [number()]
  def y_ticks(max_value, tick_count \\ 4)
  def y_ticks(max_value, _tick_count) when max_value <= 0, do: [0]

  def y_ticks(max_value, tick_count) do
    raw_step = max_value / (tick_count - 1)
    magnitude = :math.pow(10, Float.floor(:math.log10(raw_step)))
    normalised = raw_step / magnitude

    nice_step =
      cond do
        normalised <= 1 -> magnitude
        normalised <= 2 -> 2 * magnitude
        normalised <= 5 -> 5 * magnitude
        true -> 10 * magnitude
      end

    ticks =
      0.0
      |> Stream.iterate(&(&1 + nice_step))
      |> Enum.take_while(&(&1 <= max_value + nice_step * 0.01))
      |> Enum.map(&Float.round(&1, 6))

    if length(ticks) < 2, do: ticks ++ [Float.round(nice_step, 6)], else: ticks
  end

  # ── private helpers ──────────────────────────────────────────────────

  defp legend(series) do
    series |> Enum.with_index() |> Enum.map(fn {e, i} -> %{label: e.label, color: color(i)} end)
  end

  defp describe_slice(center, radius, start_angle, end_angle) do
    start_rad = (start_angle - 90) * :math.pi() / 180
    end_rad = (end_angle - 90) * :math.pi() / 180
    x1 = center + radius * :math.cos(start_rad)
    y1 = center + radius * :math.sin(start_rad)
    x2 = center + radius * :math.cos(end_rad)
    y2 = center + radius * :math.sin(end_rad)
    large_arc = if end_angle - start_angle > 180, do: 1, else: 0

    "M#{fmt(center)},#{fmt(center)} L#{fmt(x1)},#{fmt(y1)} " <>
      "A#{fmt(radius)},#{fmt(radius)} 0 #{large_arc} 1 #{fmt(x2)},#{fmt(y2)} Z"
  end

  defp cell_colors(alpha) when alpha <= 0, do: {"transparent", "inherit"}

  defp cell_colors(alpha) do
    {r, g, b} = lerp_rgb({53, 117, 56}, {183, 72, 72}, alpha)
    opacity = 0.25 + alpha * 0.75
    bg = "rgba(#{r},#{g},#{b},#{Float.round(opacity, 2)})"
    er = round(r * opacity + 30 * (1 - opacity))
    eg = round(g * opacity + 30 * (1 - opacity))
    eb = round(b * opacity + 30 * (1 - opacity))
    fg = if 0.299 * er + 0.587 * eg + 0.114 * eb > 140, do: "#000", else: "#fff"
    {bg, fg}
  end

  defp lerp_rgb({ar, ag, ab}, {br, bg, bb}, t) do
    {round(ar + (br - ar) * t), round(ag + (bg - ag) * t), round(ab + (bb - ab) * t)}
  end

  defp fmt(n) when is_integer(n), do: Integer.to_string(n)

  defp fmt(n) when is_float(n) do
    rounded = Float.round(n, 2)
    if rounded == Float.round(rounded, 0), do: Integer.to_string(trunc(rounded)), else: :erlang.float_to_binary(rounded, [:short])
  end
end
