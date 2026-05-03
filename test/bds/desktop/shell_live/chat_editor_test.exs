defmodule BDS.Desktop.ShellLive.ChatEditorTest do
  use ExUnit.Case, async: false

  test "ChatEditor exports LiveComponent callbacks" do
    assert function_exported?(BDS.Desktop.ShellLive.ChatEditor, :update, 2)
    assert function_exported?(BDS.Desktop.ShellLive.ChatEditor, :handle_event, 3)
    assert function_exported?(BDS.Desktop.ShellLive.ChatEditor, :render, 1)
  end
end
