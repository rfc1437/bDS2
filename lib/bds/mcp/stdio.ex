defmodule BDS.MCP.Stdio do
  @moduledoc false

  def main do
    IO.binstream(:stdio, :line)
    |> Enum.each(fn line ->
      line = String.trim(line)

      if line != "" do
        response =
          case Jason.decode(line) do
            {:ok, payload} ->
              handle_payload(payload)

            {:error, _reason} ->
              %{
                "jsonrpc" => "2.0",
                "id" => nil,
                "error" => %{"code" => -32700, "message" => "Parse error"}
              }
          end

        IO.write(Jason.encode!(response) <> "\n")
      end
    end)
  end

  defp handle_payload(%{
         "jsonrpc" => "2.0",
         "id" => id,
         "method" => "initialize",
         "params" => params
       }) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => Map.get(params, "protocolVersion", "2025-03-26"),
        "capabilities" => %{"tools" => %{}, "resources" => %{}},
        "serverInfo" => %{
          "name" => "Blogging Desktop Server",
          "version" => Application.spec(:bds, :vsn) |> to_string()
        }
      }
    }
  end

  defp handle_payload(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list"}) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => BDS.MCP.list_tools()}}
  end

  defp handle_payload(%{
         "jsonrpc" => "2.0",
         "id" => id,
         "method" => "tools/call",
         "params" => %{"name" => name} = params
       }) do
    case BDS.MCP.call_tool(name, Map.get(params, "arguments", %{})) do
      {:ok, result} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"content" => [%{"type" => "json", "json" => result}]}
        }

      {:error, reason} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32000, "message" => inspect(reason)}
        }
    end
  end

  defp handle_payload(%{"jsonrpc" => "2.0", "id" => id, "method" => "resources/list"}) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{"resources" => BDS.MCP.list_resources()}}
  end

  defp handle_payload(%{
         "jsonrpc" => "2.0",
         "id" => id,
         "method" => "resources/templates/list"
       }) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"resourceTemplates" => BDS.MCP.list_resource_templates()}
    }
  end

  defp handle_payload(%{
         "jsonrpc" => "2.0",
         "id" => id,
         "method" => "resources/read",
         "params" => %{"uri" => uri}
       }) do
    case BDS.MCP.read_resource(uri) do
      {:ok, result} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "contents" => [
              %{"uri" => uri, "mimeType" => "application/json", "text" => Jason.encode!(result)}
            ]
          }
        }

      {:error, reason} ->
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32000, "message" => inspect(reason)}
        }
    end
  end

  defp handle_payload(%{"jsonrpc" => "2.0", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Method not found"}
    }
  end
end
