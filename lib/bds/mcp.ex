defmodule BDS.MCP do
  @moduledoc false

  alias BDS.MCP.Resources
  alias BDS.MCP.Tools

  @typedoc "Tool descriptor returned by `list_tools/0`."
  @type tool_descriptor :: Tools.descriptor()

  @typedoc "Resource descriptor returned by `list_resources/0`."
  @type resource_descriptor :: Resources.descriptor()

  @spec list_tools() :: [tool_descriptor()]
  defdelegate list_tools(), to: Tools, as: :list

  @spec list_resources() :: [resource_descriptor()]
  defdelegate list_resources(), to: Resources, as: :list

  @spec call_tool(String.t(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate call_tool(name, params), to: Tools, as: :call

  @spec read_resource(String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate read_resource(uri), to: Resources, as: :read

  @spec validate_template(String.t()) :: {:ok, %{valid: boolean(), errors: [String.t()]}}
  defdelegate validate_template(source), to: Tools
end
