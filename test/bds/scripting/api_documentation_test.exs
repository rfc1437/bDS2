defmodule BDS.Scripting.ApiDocumentationTest do
  use ExUnit.Case, async: true

  test "rendered API docs include richer module indexes and example responses" do
    rendered = BDS.Scripting.ApiDocs.render()

    assert rendered =~ "**Module APIs**"
    assert rendered =~ "- [projects.create](#projectscreate)"
    assert rendered =~ "**Example response**"
    assert rendered =~ "- Data structures: `ProjectData`"
    assert rendered =~ "[↑ Back to Table of contents](#table-of-contents)"
  end

  test "API.md matches the generated Lua scripting contract" do
    api_doc_path = Path.expand("../../../API.md", __DIR__)

    assert File.exists?(api_doc_path)
    assert File.read!(api_doc_path) == BDS.Scripting.ApiDocs.render()
  end

  test "documented Lua methods match the live capability map" do
    documented_methods =
      BDS.Scripting.ApiDocs.render()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "### "))
      |> Enum.map(&String.replace_prefix(&1, "### ", ""))
      |> Enum.filter(&String.contains?(&1, "."))
      |> MapSet.new()

    live_methods =
      BDS.Scripting.Capabilities.for_project("project-id")
      |> Enum.flat_map(fn {module_name, functions} ->
        Enum.map(Map.keys(functions), fn function_name -> "#{module_name}.#{function_name}" end)
      end)
      |> MapSet.new()

    assert documented_methods == live_methods
  end
end
