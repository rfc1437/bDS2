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

  describe "safe_atomize_key/1" do
    test "converts known string keys to existing atoms" do
      _ = :title
      _ = :status
      assert MapUtils.safe_atomize_key("title") == :title
      assert MapUtils.safe_atomize_key("status") == :status
    end

    test "leaves unknown string keys as strings without creating new atoms" do
      unique_keys = for i <- 1..100, do: "csm001_fictive_#{i}_#{:erlang.unique_integer()}"

      Enum.each(unique_keys, fn key ->
        result = MapUtils.safe_atomize_key(key)
        assert is_binary(result)
        assert result == key
        assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
      end)
    end

    test "passes atoms through unchanged" do
      assert MapUtils.safe_atomize_key(:title) == :title
    end

    test "safe_atomize_keys recursively converts map keys safely" do
      input = %{
        "title" => "Hello",
        "status" => "draft",
        "nested" => %{"title" => "Inner", "completely_unknown_key" => "val"},
        "items" => [%{"title" => "One"}, %{"title" => "Two"}]
      }

      _ = :title
      _ = :status
      _ = :nested
      _ = :items

      result = MapUtils.safe_atomize_keys(input)

      assert result.title == "Hello"
      assert result.status == "draft"
      assert result.nested.title == "Inner"
      assert Map.get(result.nested, "completely_unknown_key") == "val"
      assert length(result.items) == 2
    end

    test "safe_atomize_keys does not create atoms for malicious payloads" do
      unique_suffix = :erlang.unique_integer()

      malicious =
        for i <- 1..500, into: %{} do
          {"csm001_malicious_#{i}_#{unique_suffix}", "val"}
        end

      result = MapUtils.safe_atomize_keys(malicious)

      assert map_size(result) == 500

      Enum.each(1..500, fn i ->
        key = "csm001_malicious_#{i}_#{unique_suffix}"
        assert Map.get(result, key) == "val"
        assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
      end)
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
