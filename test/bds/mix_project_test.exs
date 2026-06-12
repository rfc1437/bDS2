defmodule BDS.MixProjectTest do
  use ExUnit.Case, async: true

  test "validate alias runs all required quality gates" do
    aliases = BDS.MixProject.project()[:aliases]

    assert aliases[:validate] == [
             "test",
             "credo --strict",
             "deps.audit --ignore-file .mix_audit.ignore",
             "dialyzer"
           ]
  end

  test "quality tooling deps are available in dev and test" do
    deps = BDS.MixProject.project()[:deps]

    assert quality_dep(deps, :credo) == {:credo, "~> 1.7", [only: [:dev, :test], runtime: false]}

    assert quality_dep(deps, :mix_audit) ==
             {:mix_audit, "~> 2.1", [only: [:dev, :test], runtime: false]}
  end

  test "mix audit exceptions stay explicit and scoped" do
    ignore_file = File.read!(Path.expand("../../.mix_audit.ignore", __DIR__))

    assert ignore_file =~ "GHSA-rhv4-8758-jx7v"
    refute ignore_file =~ "GHSA-628h-q48j-jr6q"
  end

  test "validate runs in the test environment" do
    cli = BDS.MixProject.cli()

    assert cli[:preferred_envs][:validate] == :test
  end

  defp quality_dep(deps, app) do
    Enum.find(deps, fn
      {^app, _version} -> true
      {^app, _version, _opts} -> true
      _other -> false
    end)
  end
end