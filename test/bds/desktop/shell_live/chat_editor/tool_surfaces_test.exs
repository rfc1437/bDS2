defmodule BDS.Desktop.ShellLive.ChatEditor.ToolSurfacesTest do
  use ExUnit.Case, async: true

  alias BDS.Desktop.ShellLive.ChatEditor.ToolSurfaces

  describe "build_render_surface/3 for render_chart" do
    test "reads chartType in camelCase (as LLM sends it)" do
      tool_call = %{
        name: "render_chart",
        arguments: %{
          "chartType" => "heatmap",
          "title" => "Posts per Month",
          "series" => [
            %{"label" => "2024", "value" => 0, "segments" => [
              %{"label" => "Jan", "value" => 5},
              %{"label" => "Feb", "value" => 8}
            ]}
          ]
        }
      }

      surface = ToolSurfaces.build_render_surface(tool_call, "test-heatmap-0", %{})
      assert surface.type == "chart"
      assert surface.chart_type == "heatmap"
    end

    test "reads chart_type in snake_case (legacy form)" do
      tool_call = %{
        name: "render_chart",
        arguments: %{"chart_type" => "pie", "series" => []}
      }

      surface = ToolSurfaces.build_render_surface(tool_call, "test-pie-0", %{})
      assert surface.chart_type == "pie"
    end

    test "defaults to bar when chartType field is missing" do
      tool_call = %{
        name: "render_chart",
        arguments: %{"title" => "No type", "series" => []}
      }

      surface = ToolSurfaces.build_render_surface(tool_call, "test-bar-0", %{})
      assert surface.chart_type == "bar"
    end

    test "handles all chart types via camelCase" do
      for chart_type <- ["bar", "stacked-bar", "line", "area", "pie", "donut", "heatmap"] do
        tool_call = %{
          name: "render_chart",
          arguments: %{"chartType" => chart_type, "series" => []}
        }

        surface = ToolSurfaces.build_render_surface(tool_call, "test-#{chart_type}-0", %{})
        assert surface.chart_type == chart_type,
          "Expected chart_type #{inspect(chart_type)}, got #{inspect(surface.chart_type)}"
      end
    end
  end
end
