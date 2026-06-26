defmodule BDS.ValuesTest do
  use ExUnit.Case, async: true

  alias BDS.Values

  describe "present?/1 and blank?/1 (non-trimming)" do
    test "nil and empty string are blank" do
      assert Values.blank?(nil)
      assert Values.blank?("")
      refute Values.present?(nil)
      refute Values.present?("")
    end

    test "whitespace-only strings are PRESENT (non-trimming contract)" do
      # Crucial: matches BDS.MapUtils.blank_to_nil/1 — a trim-aware caller must
      # compose String.trim/1 itself.
      assert Values.present?(" ")
      assert Values.present?("\n")
      refute Values.blank?(" ")
      refute Values.blank?("\n")
    end

    test "non-empty values are present" do
      for v <- ["x", 0, 1, 1.0, false, true] do
        assert Values.present?(v)
        refute Values.blank?(v)
      end
    end
  end

  describe "truthy?/1" do
    test "accepts the canonical truthy set" do
      for v <- [true, "true", "on", 1, 1.0, "1"] do
        assert Values.truthy?(v)
      end
    end

    test "rejects everything else" do
      for v <- [false, "false", "off", 0, "0", nil, "", "yes", 2] do
        refute Values.truthy?(v)
      end
    end
  end

  test "blank_to_nil/1 delegates to MapUtils (non-trimming)" do
    assert Values.blank_to_nil(nil) == nil
    assert Values.blank_to_nil("") == nil
    assert Values.blank_to_nil(" ") == " "
    assert Values.blank_to_nil("x") == "x"
  end
end
