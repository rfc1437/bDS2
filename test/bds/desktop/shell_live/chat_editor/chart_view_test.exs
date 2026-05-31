defmodule Bds.Desktop.ShellLive.ChatEditor.ChartViewTest do
  use ExUnit.Case, async: true

  alias BDS.Desktop.ShellLive.ChatEditor.ChartView

  defp entry(label, value, segments \\ []) do
    %{label: label, value: value, segments: segments}
  end

  defp seg(label, value), do: %{label: label, value: value}

  describe "y_ticks/1" do
    test "always starts at zero and reaches the max value" do
      ticks = ChartView.y_ticks(100)
      assert List.first(ticks) == 0.0
      assert List.last(ticks) >= 100
    end

    test "returns [0] for non-positive maxima" do
      assert ChartView.y_ticks(0) == [0]
    end

    test "produces nice rounded steps" do
      assert ChartView.y_ticks(100) == [0.0, 50.0, 100.0]
    end
  end

  describe "pie/1" do
    test "produces one slice and legend item per series entry" do
      result = ChartView.pie([entry("A", 1), entry("B", 3)])
      assert length(result.slices) == 2
      assert length(result.legend) == 2
      assert result.total == 4
      assert [%{d: "M" <> _}, _] = result.slices
    end

    test "uses a full circle for a single slice" do
      result = ChartView.pie([entry("Only", 5)])
      assert [%{full_circle: true, d: nil}] = result.slices
    end

    test "distinct colours come from the palette" do
      result = ChartView.pie([entry("A", 1), entry("B", 1)])
      colours = Enum.map(result.slices, & &1.color)
      assert colours == Enum.uniq(colours)
    end

    test "empty series yields no slices" do
      assert %{slices: [], total: 0} = ChartView.pie([])
    end
  end

  describe "line/2" do
    test "produces a dot and polyline point per entry" do
      result = ChartView.line([entry("Jan", 10), entry("Feb", 20)], false)
      assert length(result.dots) == 2
      assert result.polyline =~ ","
      assert result.area? == false
      assert result.area_points == ""
    end

    test "area mode builds a closed polygon" do
      result = ChartView.line([entry("Jan", 10), entry("Feb", 20)], true)
      assert result.area? == true
      assert result.area_points != ""
    end

    test "gridlines and y labels are derived from ticks" do
      result = ChartView.line([entry("Jan", 100)], false)
      assert length(result.grid) >= 2
      assert Enum.all?(result.grid, &is_binary(&1.label))
    end
  end

  describe "heatmap/1" do
    test "builds columns from segment labels and a cell per column" do
      series = [
        entry("2024", 0, [seg("Jan", 2), seg("Feb", 4)]),
        entry("2025", 0, [seg("Jan", 1), seg("Feb", 8)])
      ]

      result = ChartView.heatmap(series)
      assert result.columns == ["Jan", "Feb"]
      assert result.column_count == 2
      assert length(result.rows) == 2
      assert Enum.all?(result.rows, &(length(&1.cells) == 2))
    end

    test "zero-valued cells are transparent" do
      series = [entry("2024", 0, [seg("Jan", 0), seg("Feb", 5)])]
      [row] = ChartView.heatmap(series).rows
      assert [%{value: 0, bg: "transparent", fg: "inherit"}, %{value: 5}] = row.cells
    end

    test "ignores entries without segments" do
      assert %{rows: [], columns: []} = ChartView.heatmap([entry("plain", 5)])
    end
  end

  describe "stacked/1" do
    test "computes segment widths against the largest stacked total" do
      series = [
        entry("2024", 0, [seg("draft", 1), seg("published", 1)]),
        entry("2025", 0, [seg("draft", 2), seg("published", 2)])
      ]

      result = ChartView.stacked(series)
      assert result.max_total == 4
      assert result.legend == [%{label: "draft", color: ChartView.color(0)}, %{label: "published", color: ChartView.color(1)}]

      first_row = List.first(result.rows)
      assert first_row.total == 2
      assert Enum.map(first_row.segments, & &1.width) == ["25", "25"]
    end

    test "segment colours are keyed by label, consistent across rows" do
      series = [
        entry("a", 0, [seg("x", 1), seg("y", 1)]),
        entry("b", 0, [seg("y", 1)])
      ]

      result = ChartView.stacked(series)
      [row_a, row_b] = result.rows
      y_in_a = Enum.find(row_a.segments, &(&1.label == "y"))
      y_in_b = Enum.find(row_b.segments, &(&1.label == "y"))
      assert y_in_a.color == y_in_b.color
    end
  end
end
