defmodule BDS.CSM036FileSplitTest do
  use ExUnit.Case, async: false

  @shell_live_path "lib/bds/desktop/shell_live.ex"
  @shell_live_content_state_path "lib/bds/desktop/shell_live/content_state.ex"
  @chat_path "lib/bds/ai/chat.ex"
  @chat_title_generator_path "lib/bds/ai/chat_title_generator.ex"
  @chat_tools_path "lib/bds/ai/chat_tools.ex"
  @chat_tool_schemas_path "lib/bds/ai/chat_tool_schemas.ex"

  describe "source-level: shell_live refresh orchestration split" do
    test "shell_live delegates refresh_content and reload_shell to a helper module" do
      shell_live_source = File.read!(@shell_live_path)
      content_state_source = File.read!(@shell_live_content_state_path)

      refute shell_live_source =~ "defp refresh_content(socket, workbench) do"
      refute shell_live_source =~ "defp reload_shell(socket, workbench) do"

      assert shell_live_source =~ "defp refresh_content(socket, workbench), do: ContentState.refresh_content(socket, workbench)"
      assert shell_live_source =~ "defp reload_shell(socket, workbench), do: ContentState.reload_shell(socket, workbench)"

      assert content_state_source =~ "def refresh_content(socket, workbench) do"
      assert content_state_source =~ "def reload_shell(socket, workbench) do"
    end
  end

  describe "source-level: ai chat title split" do
    test "chat title generation logic lives in a dedicated helper module" do
      chat_source = File.read!(@chat_path)
      title_generator_source = File.read!(@chat_title_generator_path)

      refute chat_source =~ "defp generate_chat_title(user_content, opts)"
      refute chat_source =~ "defp build_chat_title_request(user_content, model)"
      refute chat_source =~ "defp sanitize_chat_title(title) when is_binary(title)"

      assert title_generator_source =~ "def generate_chat_title(user_content, opts)"
      assert title_generator_source =~ "def build_chat_title_request(user_content, model)"
      assert title_generator_source =~ "def sanitize_chat_title(title) when is_binary(title)"
    end
  end

  describe "source-level: ai chat tool schema split" do
    test "chat tool JSON schema builders live in a dedicated helper module" do
      chat_tools_source = File.read!(@chat_tools_path)
      chat_tool_schemas_source = File.read!(@chat_tool_schemas_path)

      refute chat_tools_source =~ "defp tool_spec(name, description, parameters) do"
      refute chat_tools_source =~ "defp render_chart_schema do"
      refute chat_tools_source =~ "defp render_form_schema do"
      refute chat_tools_source =~ "defp post_search_schema(require_query) do"

      assert chat_tool_schemas_source =~ "def tool_spec(name, description, parameters) do"
      assert chat_tool_schemas_source =~ "def render_chart_schema do"
      assert chat_tool_schemas_source =~ "def render_form_schema do"
      assert chat_tool_schemas_source =~ "def post_search_schema(require_query) do"
    end
  end
end
