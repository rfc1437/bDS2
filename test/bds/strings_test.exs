defmodule BDS.StringsTest do
  use ExUnit.Case, async: true

  alias BDS.Strings

  test "pad2/1 zero-pads to at least two digits" do
    assert Strings.pad2(0) == "00"
    assert Strings.pad2(3) == "03"
    assert Strings.pad2(12) == "12"
    assert Strings.pad2(123) == "123"
  end
end
