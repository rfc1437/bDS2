defmodule BDS.SpecCoverageTest do
  use ExUnit.Case, async: true

  @section_10_files [
    "lib/bds/tags.ex",
    "lib/bds/templates.ex",
    "lib/bds/scripts.ex",
    "lib/bds/post_links.ex"
  ]

  @section_10_editor_globs [
    "lib/bds/desktop/shell_live/*editor.ex",
    "lib/bds/desktop/shell_live/*_editor/*.ex"
  ]

  describe "CODESMELL Section 10" do
    test "smaller contexts have specs for all public functions" do
      root = File.cwd!()

      offenders =
        section_10_files(root)
        |> Enum.flat_map(fn relative_path ->
          relative_path
          |> Path.join("")
          |> then(&Path.join(root, &1))
          |> public_functions_without_specs(relative_path)
        end)

      assert offenders == []
    end
  end

  defp section_10_files(root) do
    editor_files =
      @section_10_editor_globs
      |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(root, pattern)) end)
      |> Enum.map(&Path.relative_to(&1, root))

    (@section_10_files ++ editor_files)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp public_functions_without_specs(path, relative_path) do
    source = File.read!(path)
    {:ok, ast} = Code.string_to_quoted(source)

    specs = spec_names(source)

    ast
    |> public_defs()
    |> Enum.uniq_by(fn {_line, name, arity} -> {name, arity} end)
    |> Enum.reject(fn {_line, name, _arity} -> MapSet.member?(specs, name) end)
    |> Enum.map(fn {line, name, arity} -> "#{relative_path}:#{line}:#{name}/#{arity}" end)
  end

  defp spec_names(source) do
    ~r/^\s*@spec\s+([a-zA-Z_][a-zA-Z0-9_?!]*)\s*\(/m
    |> Regex.scan(source)
    |> Enum.map(fn [_match, name] -> String.to_atom(name) end)
    |> MapSet.new()
  end

  defp public_defs(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [head | _]} = node, acc ->
          {name, arity} = public_def_name_arity(head)
          {node, [{Keyword.fetch!(meta, :line), name, arity} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(defs)
  end

  defp public_def_name_arity({:when, _meta, [head | _guards]}), do: public_def_name_arity(head)

  defp public_def_name_arity({name, _meta, args}) when is_atom(name),
    do: {name, length(args || [])}
end
