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
end
