defmodule BDS.Desktop.ShellLive.ImportEditorTest do
  use ExUnit.Case, async: false

  test "ImportEditor exports LiveComponent callbacks" do
    module = BDS.Desktop.ShellLive.ImportEditor
    assert Code.ensure_loaded?(module)
    assert function_exported?(module, :update, 2)
    assert function_exported?(module, :handle_event, 3)
    assert function_exported?(module, :render, 1)
  end
end
