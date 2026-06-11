defmodule BDS.AI.OpenAICompatibleRuntime do
  @moduledoc false

  require Logger

  alias BDS.AI.HttpClient
  alias BDS.AI.SSE

  def list_models(endpoint, opts \\ []) when is_map(endpoint) and is_list(opts) do
    http_client = Keyword.get(opts, :http_client, HttpClient)
    url = models_url(endpoint.url)

    headers =
      %{"accept" => "application/json"}
      |> maybe_put_auth(endpoint.api_key)

    with {:ok, response} <- http_client.get(url, headers),
         200 <- response.status do
      normalize_models_response(response.body)
    else
      status when is_integer(status) -> {:error, %{kind: :http_error, status: status}}
      {:error, reason} -> {:error, %{kind: :http_error, reason: reason}}
    end
  end

  def generate(endpoint, request, opts) when is_map(endpoint) and is_map(request) do
    url = completions_url(endpoint.url)

    headers =
      %{
        "content-type" => "application/json",
        "accept" => "application/json"
      }
      |> maybe_put_auth(endpoint.api_key)

    payload =
      %{
        "model" => request.model,
        "messages" => request.messages,
        "max_tokens" => request.max_output_tokens
      }
      |> maybe_disable_thinking(request.model)
      |> maybe_put_tools(Map.get(request, :tools, []))

    if stream?(request, opts) do
      generate_streaming(url, headers, payload, request, Keyword.fetch!(opts, :on_stream))
    else
      generate_blocking(url, headers, payload, request)
    end
  end

  defp generate_blocking(url, headers, payload, request) do
    payload_json = Jason.encode!(payload)

    Logger.debug(
      "AI OpenAI-compatible request operation=#{inspect(Map.get(request, :operation))} model=#{inspect(request.model)} url=#{url} tools=#{payload |> Map.get("tools", []) |> length()} payload_size=#{byte_size(payload_json)}"
    )

    case HttpClient.post(url, headers, payload_json) do
      {:ok, %{status: 200, body: body}} ->
        result = normalize_response(body)

        case result do
          {:ok, %{json: nil, content: content}} when is_binary(content) ->
            Logger.debug(
              "AI OpenAI-compatible response parsed but content is not valid JSON. Content: #{String.slice(content, 0, 500)}"
            )

          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "AI OpenAI-compatible response normalization failed: #{inspect(reason)} body=#{String.slice(body, 0, 1000)}"
            )
        end

        result

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "AI OpenAI-compatible HTTP error status=#{status} body=#{String.slice(body, 0, 2000)}"
        )

        {:error, %{kind: :http_error, status: status, body: body}}

      {:error, reason} ->
        Logger.error("AI OpenAI-compatible HTTP request failed: #{inspect(reason)}")
        {:error, %{kind: :http_error, reason: reason}}
    end
  end

  # Streaming variant: same request payload plus stream flags; SSE chunks are
  # folded into a BDS.AI.SSE assembler that emits cumulative content
  # snapshots to `on_stream` as they arrive. The assembled message goes
  # through the same normalization as the blocking path.
  defp generate_streaming(url, headers, payload, request, on_stream) do
    payload_json =
      payload
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})
      |> Jason.encode!()

    Logger.debug(
      "AI OpenAI-compatible streaming request operation=#{inspect(Map.get(request, :operation))} model=#{inspect(request.model)} url=#{url} payload_size=#{byte_size(payload_json)}"
    )

    sse = SSE.new(on_stream, emit_interval_ms: stream_emit_interval_ms())

    case HttpClient.post_stream(url, headers, payload_json, sse, fn chunk, acc ->
           SSE.feed(acc, chunk)
         end) do
      {:ok, %{status: 200, headers: response_headers}, sse} ->
        if event_stream?(response_headers) do
          assembled = SSE.finish(sse)

          {:ok,
           %{
             content: assembled.content,
             json: decode_json_content(assembled.content),
             tool_calls: normalize_tool_calls(assembled.tool_calls),
             usage: normalize_usage(assembled.usage || %{})
           }}
        else
          # The provider ignored the stream flag and sent a plain completion.
          normalize_response(SSE.raw_body(sse))
        end

      {:ok, %{status: status, body: body}, _sse} ->
        Logger.error(
          "AI OpenAI-compatible streaming HTTP error status=#{status} body=#{String.slice(body, 0, 2000)}"
        )

        {:error, %{kind: :http_error, status: status, body: body}}

      {:error, reason} ->
        Logger.error("AI OpenAI-compatible streaming request failed: #{inspect(reason)}")
        {:error, %{kind: :http_error, reason: reason}}
    end
  end

  # Streaming is opt-in per request (the caller passes :on_stream), limited
  # to interactive chat, and can be disabled globally for providers that do
  # not support SSE (config :bds, :chat, streaming: false).
  defp stream?(request, opts) do
    Map.get(request, :operation) == :chat and
      is_function(Keyword.get(opts, :on_stream), 1) and
      chat_config(:streaming, true)
  end

  defp stream_emit_interval_ms, do: chat_config(:stream_emit_interval_ms, 100)

  defp event_stream?(headers) do
    case headers["content-type"] do
      content_type when is_binary(content_type) ->
        String.contains?(content_type, "text/event-stream")

      _missing ->
        # No content type: trust the request we made and parse as SSE.
        true
    end
  end

  defp chat_config(key, default) do
    :bds |> Application.get_env(:chat, []) |> Keyword.get(key, default)
  end

  defp normalize_response(body) do
    with {:ok, payload} <- decode_json_body(body) do
      message = get_in(payload, ["choices", Access.at(0), "message"]) || %{}
      content = normalize_content(message["content"])
      tool_calls = normalize_tool_calls(message["tool_calls"] || [])
      usage = normalize_usage(payload["usage"] || %{})

      {:ok,
       %{
         content: content,
         json: decode_json_content(content),
         tool_calls: tool_calls,
         usage: usage
       }}
    end
  end

  defp decode_json_content(content), do: BDS.AI.JsonContent.decode(content)

  defp completions_url(url) do
    cond do
      String.ends_with?(url, "/chat/completions") -> url
      String.ends_with?(url, "/") -> url <> "chat/completions"
      true -> url <> "/chat/completions"
    end
  end

  defp models_url(url) do
    cond do
      String.ends_with?(url, "/chat/completions") ->
        String.replace_suffix(url, "/chat/completions", "/models")

      String.ends_with?(url, "/models") ->
        url

      String.ends_with?(url, "/") ->
        url <> "models"

      true ->
        url <> "/models"
    end
  end

  defp normalize_models_response(body) do
    with {:ok, payload} <- decode_json_body(body) do
      models =
        payload
        |> Map.get("data", [])
        |> Enum.map(fn entry ->
          id = entry["id"] || entry[:id]

          %{
            id: id,
            label: id
          }
        end)
        |> Enum.reject(&is_nil(&1.id))
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&String.downcase(&1.id))

      {:ok, models}
    end
  end

  defp decode_json_body(body) do
    case Jason.decode(body) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, %{kind: :invalid_json_response, reason: reason}}
    end
  end

  defp maybe_put_auth(headers, nil), do: headers
  defp maybe_put_auth(headers, ""), do: headers

  defp maybe_put_auth(headers, api_key),
    do: Map.put(headers, "authorization", "Bearer #{api_key}")

  defp maybe_put_tools(payload, []), do: payload
  defp maybe_put_tools(payload, nil), do: payload

  defp maybe_put_tools(payload, tools) do
    Map.put(payload, "tools", tools)
    |> Map.put("tool_choice", "auto")
  end

  defp maybe_disable_thinking(payload, model) when is_binary(model) do
    if BDS.AI.Catalog.model_capabilities(model).disables_reasoning do
      Map.update(payload, "chat_template_kwargs", %{"enable_thinking" => false}, fn kwargs ->
        Map.put(kwargs || %{}, "enable_thinking", false)
      end)
    else
      payload
    end
  end

  defp maybe_disable_thinking(payload, _model), do: payload

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
