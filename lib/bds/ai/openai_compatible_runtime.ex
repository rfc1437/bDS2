defmodule BDS.AI.OpenAICompatibleRuntime do
  @moduledoc false

  alias BDS.AI.HttpClient

  def generate(endpoint, request, _opts) when is_map(endpoint) and is_map(request) do
    url = completions_url(endpoint.url)

    headers =
      %{
        "content-type" => "application/json",
        "accept" => "application/json"
      }
      |> maybe_put_auth(endpoint.api_key)

    payload = %{
      "model" => request.model,
      "messages" => request.messages,
      "max_tokens" => request.max_output_tokens
    }
    |> maybe_put_tools(request.tools)

    with {:ok, response} <- HttpClient.post(url, headers, Jason.encode!(payload)),
         200 <- response.status do
      normalize_response(response.body)
    else
      status when is_integer(status) -> {:error, %{kind: :http_error, status: status}}
      {:error, reason} -> {:error, %{kind: :http_error, reason: reason}}
    end
  end

  defp normalize_response(body) do
    payload = Jason.decode!(body)
    message = get_in(payload, ["choices", Access.at(0), "message"]) || %{}
    content = normalize_content(message["content"])
    tool_calls = normalize_tool_calls(message["tool_calls"] || [])
    usage = normalize_usage(payload["usage"] || %{})

    json =
      case content do
        nil -> nil
        value when is_binary(value) ->
          case Jason.decode(value) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _other -> nil
          end
      end

    {:ok, %{content: content, json: json, tool_calls: tool_calls, usage: usage}}
  end

  defp completions_url(url) do
    cond do
      String.ends_with?(url, "/chat/completions") -> url
      String.ends_with?(url, "/") -> url <> "chat/completions"
      true -> url <> "/chat/completions"
    end
  end

  defp maybe_put_auth(headers, nil), do: headers
  defp maybe_put_auth(headers, ""), do: headers
  defp maybe_put_auth(headers, api_key), do: Map.put(headers, "authorization", "Bearer #{api_key}")

  defp maybe_put_tools(payload, []), do: payload
  defp maybe_put_tools(payload, nil), do: payload

  defp maybe_put_tools(payload, tools) do
    Map.put(payload, "tools", tools)
    |> Map.put("tool_choice", "auto")
  end

  defp normalize_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      %{
        id: tool_call["id"],
        name: get_in(tool_call, ["function", "name"]),
        arguments: decode_arguments(get_in(tool_call, ["function", "arguments"]))
      }
    end)
  end

  defp decode_arguments(nil), do: %{}

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp normalize_content(nil), do: nil
  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_list(content) do
    content
    |> Enum.map(fn item -> item["text"] || "" end)
    |> Enum.join()
  end

  defp normalize_usage(usage) do
    %{
      input_tokens: usage["prompt_tokens"],
      output_tokens: usage["completion_tokens"],
      cache_read_tokens: get_in(usage, ["prompt_tokens_details", "cached_tokens"]),
      cache_write_tokens: get_in(usage, ["completion_tokens_details", "cached_tokens"])
    }
  end
end
