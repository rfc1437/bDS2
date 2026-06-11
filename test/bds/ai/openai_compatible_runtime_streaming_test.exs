defmodule BDS.AI.OpenAICompatibleRuntimeStreamingTest do
  use ExUnit.Case, async: false

  alias BDS.AI.OpenAICompatibleRuntime

  defmodule SSEPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)
      send(test_pid(), {:endpoint_request, payload})

      respond(conn, payload["model"], payload)
    end

    defp respond(conn, "stream-content", %{"stream" => true}) do
      stream(conn, [
        delta_event(%{"role" => "assistant", "content" => ""}),
        delta_event(%{"content" => "Once"}),
        delta_event(%{"content" => " upon"}),
        delta_event(%{"content" => " a time"}),
        ~s(data: ) <>
          Jason.encode!(%{
            "choices" => [],
            "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 3}
          }) <> "\n\n",
        "data: [DONE]\n\n"
      ])
    end

    defp respond(conn, "stream-tools", %{"stream" => true}) do
      stream(conn, [
        delta_event(%{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call-1",
              "function" => %{"name" => "search_posts", "arguments" => ""}
            }
          ]
        }),
        delta_event(%{
          "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"query\":"}}]
        }),
        delta_event(%{
          "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\"sun\"}"}}]
        }),
        "data: [DONE]\n\n"
      ])
    end

    defp respond(conn, "stream-error", %{"stream" => true}) do
      send_resp(conn, 503, ~s({"error":"overloaded"}))
    end

    # Simulates a provider that ignores the "stream" flag and answers with a
    # plain JSON completion.
    defp respond(conn, "ignores-stream", %{"stream" => true}) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => "plain json despite stream"}}],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2}
        })
      )
    end

    defp respond(conn, _model, _payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => "non-streaming reply"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      )
    end

    defp delta_event(delta) do
      "data: " <> Jason.encode!(%{"choices" => [%{"delta" => delta}]}) <> "\n\n"
    end

    defp stream(conn, events) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      Enum.reduce_while(events, conn, fn event, conn ->
        case chunk(conn, event) do
          {:ok, conn} -> {:cont, conn}
          {:error, _reason} -> {:halt, conn}
        end
      end)
    end

    defp test_pid, do: Application.get_env(:bds, :sse_plug_test_pid)
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Application.put_env(:bds, :sse_plug_test_pid, self())

    original_chat = Application.fetch_env(:bds, :chat)

    Application.put_env(
      :bds,
      :chat,
      Keyword.merge(Application.get_env(:bds, :chat, []), stream_emit_interval_ms: 0)
    )

    on_exit(fn ->
      case original_chat do
        {:ok, value} -> Application.put_env(:bds, :chat, value)
        :error -> Application.delete_env(:bds, :chat)
      end
    end)

    server = start_supervised!({Bandit, plug: SSEPlug, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, url: "http://127.0.0.1:#{port}/v1"}
  end

  defp chat_request(model) do
    %{
      operation: :chat,
      model: model,
      max_output_tokens: 64,
      messages: [%{"role" => "user", "content" => "hello"}]
    }
  end

  defp stream_collector do
    test_pid = self()
    fn event -> send(test_pid, {:stream_event, event}) end
  end

  test "generate streams cumulative content and returns the assembled response", %{url: url} do
    assert {:ok, response} =
             OpenAICompatibleRuntime.generate(
               %{url: url, api_key: "sk-test"},
               chat_request("stream-content"),
               on_stream: stream_collector()
             )

    assert response.content == "Once upon a time"
    assert response.tool_calls == []
    assert response.usage.input_tokens == 7
    assert response.usage.output_tokens == 3

    assert_received {:endpoint_request, payload}
    assert payload["stream"] == true
    assert payload["stream_options"] == %{"include_usage" => true}

    assert_received {:stream_event, %{content: "Once"}}
    assert_received {:stream_event, %{content: "Once upon"}}
    assert_received {:stream_event, %{content: "Once upon a time"}}
  end

  test "generate assembles tool calls streamed as fragments", %{url: url} do
    assert {:ok, response} =
             OpenAICompatibleRuntime.generate(
               %{url: url, api_key: "sk-test"},
               chat_request("stream-tools"),
               on_stream: stream_collector()
             )

    assert response.content == nil

    assert response.tool_calls == [
             %{id: "call-1", name: "search_posts", arguments: %{"query" => "sun"}}
           ]
  end

  test "an error status during streaming surfaces as a structured error", %{url: url} do
    assert {:error, %{kind: :http_error, status: 503}} =
             OpenAICompatibleRuntime.generate(
               %{url: url, api_key: "sk-test"},
               chat_request("stream-error"),
               on_stream: stream_collector()
             )
  end

  test "a provider that ignores the stream flag still produces a full response", %{url: url} do
    assert {:ok, response} =
             OpenAICompatibleRuntime.generate(
               %{url: url, api_key: "sk-test"},
               chat_request("ignores-stream"),
               on_stream: stream_collector()
             )

    assert response.content == "plain json despite stream"
    assert response.usage.input_tokens == 5
    assert response.usage.output_tokens == 2
  end

  test "streaming is skipped when disabled via config", %{url: url} do
    Application.put_env(
      :bds,
      :chat,
      Keyword.merge(Application.get_env(:bds, :chat, []), streaming: false)
    )

    assert {:ok, %{content: "non-streaming reply"}} =
             OpenAICompatibleRuntime.generate(
               %{url: url, api_key: "sk-test"},
               chat_request("any-model"),
               on_stream: stream_collector()
             )

    assert_received {:endpoint_request, payload}
    refute Map.has_key?(payload, "stream")
    refute_received {:stream_event, _event}
  end

  test "streaming requires an on_stream callback", %{url: url} do
    assert {:ok, %{content: "non-streaming reply"}} =
             OpenAICompatibleRuntime.generate(
               %{url: url, api_key: "sk-test"},
               chat_request("any-model"),
               []
             )

    assert_received {:endpoint_request, payload}
    refute Map.has_key?(payload, "stream")
  end

  test "non-chat operations never stream", %{url: url} do
    request = %{
      operation: :chat_title,
      model: "any-model",
      max_output_tokens: 32,
      messages: [%{"role" => "user", "content" => "Topic: hello"}]
    }

    assert {:ok, %{content: "non-streaming reply"}} =
             OpenAICompatibleRuntime.generate(
               %{url: url, api_key: "sk-test"},
               request,
               on_stream: stream_collector()
             )

    assert_received {:endpoint_request, payload}
    refute Map.has_key?(payload, "stream")
  end
end
