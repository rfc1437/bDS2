defmodule BDS.MapUtilsTest do
  use ExUnit.Case, async: true

  alias BDS.MapUtils

  describe "attr/2" do
    test "reads atom and string keys while preserving explicit nil" do
      assert MapUtils.attr(%{title: "Atom title"}, :title) == "Atom title"
      assert MapUtils.attr(%{"title" => "String title"}, :title) == "String title"
      assert MapUtils.attr(%{"title" => "fallback", title: nil}, :title) == nil
      assert MapUtils.attr(%{}, :title) == nil
    end

    test "reads with a default while preserving explicit nil and false" do
      assert MapUtils.attr(%{}, :published, true) == true
      assert MapUtils.attr(%{"published" => false}, :published, true) == false
      assert MapUtils.attr(%{"published" => nil}, :published, true) == nil
    end
  end

  describe "maybe_put/3" do
    test "skips nil values and keeps other values" do
      assert MapUtils.maybe_put(%{}, :title, nil) == %{}
      assert MapUtils.maybe_put(%{}, :title, "") == %{title: ""}
      assert MapUtils.maybe_put(%{}, :published, false) == %{published: false}
    end
  end

  describe "blank_to_nil/1" do
    test "normalizes nil and empty string only" do
      assert MapUtils.blank_to_nil(nil) == nil
      assert MapUtils.blank_to_nil("") == nil
      assert MapUtils.blank_to_nil(" ") == " "
      assert MapUtils.blank_to_nil(42) == 42
    end
  end

  describe "atom/string key duality" do
    test "shared attr helper is used for same-name atom and string reads" do
      root = File.cwd!()

      offenders =
        [Path.join(root, "lib/**/*.ex"), Path.join(root, "lib/**/*.heex")]
        |> Enum.flat_map(&Path.wildcard/1)
        |> Enum.flat_map(fn path ->
          path
          |> File.stream!()
          |> Stream.with_index(1)
          |> Enum.flat_map(fn {line, line_number} ->
            if same_name_dual_key_read?(line) do
              ["#{Path.relative_to(path, root)}:#{line_number}:#{String.trim(line)}"]
            else
              []
            end
          end)
        end)

      assert offenders == []
    end
  end

  defp same_name_dual_key_read?(line) do
    Regex.match?(
      ~r/Map\.get\((\w+),\s*:([a-zA-Z_][a-zA-Z0-9_?!]*)\).{0,120}Map\.get\(\1,\s*"\2"\)/,
      line
    ) or
      Regex.match?(
        ~r/Map\.get\((\w+),\s*:([a-zA-Z_][a-zA-Z0-9_?!]*),\s*Map\.get\(\1,\s*"\2"/,
        line
      ) or
      Regex.match?(
        ~r/Map\.get\((\w+),\s*"([a-zA-Z_][a-zA-Z0-9_?!]*)"\).{0,120}Map\.get\(\1,\s*:\2\)/,
        line
      ) or
      Regex.match?(
        ~r/Map\.get\((\w+),\s*"([a-zA-Z_][a-zA-Z0-9_?!]*)",\s*Map\.get\(\1,\s*:\2/,
        line
      )
  end
end
