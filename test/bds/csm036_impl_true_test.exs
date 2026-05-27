defmodule BDS.CSM036ImplTrueTest do
  use ExUnit.Case, async: true

  @publishing_source File.read!("lib/bds/publishing.ex")

  describe "CSM-036: @impl true on GenServer callbacks" do
    test "every handle_call clause has @impl true" do
      lines = String.split(@publishing_source, "\n")

      handle_call_lines =
        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _idx} ->
          String.contains?(line, "def handle_call(")
        end)

      assert length(handle_call_lines) >= 5, "expected at least 5 handle_call clauses"

      for {_line, idx} <- handle_call_lines do
        preceding = Enum.at(lines, idx - 2)

        assert String.contains?(preceding, "@impl true"),
               "handle_call at line #{idx} missing @impl true (preceding line: #{inspect(preceding)})"
      end
    end

    test "no handle_cast, handle_info, or terminate without @impl true" do
      lines = String.split(@publishing_source, "\n")

      callback_lines =
        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _idx} ->
          Regex.match?(~r/^\s+def (handle_cast|handle_info|terminate)\(/, line)
        end)

      for {_line, idx} <- callback_lines do
        preceding = Enum.at(lines, idx - 2)

        assert String.contains?(preceding, "@impl true"),
               "callback at line #{idx} missing @impl true"
      end
    end
  end
end
