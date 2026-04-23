defmodule BDSTest do
  use ExUnit.Case, async: false

  test "the repo module is configured" do
    assert BDS.Repo.config()[:otp_app] == :bds
  end
end
