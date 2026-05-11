defmodule BDS.CSM021CondPatternMatchTest do
  use ExUnit.Case, async: true

  describe "source-level: no cond blocks in fixed files" do
    test "ai.ex has no cond do blocks" do
      source = File.read!("lib/bds/ai.ex")
      refute source =~ "cond do", "ai.ex should not contain cond do"
    end

    test "api_docs.ex has no cond do blocks" do
      source = File.read!("lib/bds/scripting/api_docs.ex")
      refute source =~ "cond do", "api_docs.ex should not contain cond do"
    end
  end
end
