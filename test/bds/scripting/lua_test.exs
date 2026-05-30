defmodule BDS.Scripting.LuaTest do
  use ExUnit.Case, async: true

  test "validates Lua source" do
    assert :ok = BDS.Scripting.validate("function main() return 42 end")
  end

  test "rejects invalid Lua source" do
    assert {:error, {:compile_error, _details}} = BDS.Scripting.validate("function main(")
  end

  test "executes the configured entrypoint in a sandboxed Lua runtime" do
    source = "function main(a, b) return a + b end"

    assert {:ok, 42} = BDS.Scripting.execute(source, "main", [19, 23])
  end

  test "exposes progress reporting through the host boundary" do
    parent = self()

    source = """
    function main()
      bds.report_progress({phase = 'fetch', current = 1, total = 2})
      bds.report_progress({phase = 'write', current = 2, total = 2})
      return 'done'
    end
    """

    callback = fn progress -> send(parent, {:progress, progress}) end

    assert {:ok, "done"} = BDS.Scripting.execute(source, "main", [], on_progress: callback)

    assert_receive {:progress, %{"phase" => "fetch", "current" => 1, "total" => 2}}
    assert_receive {:progress, %{"phase" => "write", "current" => 2, "total" => 2}}
  end

  test "sandbox blocks os.execute" do
    source = "function main() os.execute('echo hacked') end"

    assert {:error, _reason} = BDS.Scripting.execute(source, "main", [])
  end

  test "sandbox blocks os.rename" do
    source = "function main() os.rename('/etc/passwd', '/tmp/hacked') end"

    assert {:error, _reason} = BDS.Scripting.execute(source, "main", [])
  end

  test "sandbox blocks io.open for writing" do
    source = "function main() io.open('/tmp/hacked', 'w') end"

    assert {:error, _reason} = BDS.Scripting.execute(source, "main", [])
  end

  test "sandbox blocks require" do
    source = "function main() require('socket') end"

    assert {:error, _reason} = BDS.Scripting.execute(source, "main", [])
  end

  test "sandbox blocks dofile" do
    source = "function main() dofile('/etc/hosts') end"

    assert {:error, _reason} = BDS.Scripting.execute(source, "main", [])
  end

  test "sandbox blocks loadlib" do
    source = "function main() package.loadlib('libc.so', 'system') end"

    assert {:error, _reason} = BDS.Scripting.execute(source, "main", [])
  end

  test "enforces reduction limits" do
    source = "function main() while true do end end"

    assert {:error, {:reductions_exceeded, _count}} =
             BDS.Scripting.execute(source, "main", [], timeout: 1_000, max_reductions: 100)
  end
end
