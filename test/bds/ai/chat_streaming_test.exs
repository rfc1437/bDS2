defmodule BDS.AI.ChatStreamingTest do
  use ExUnit.Case, async: false

  defmodule FakeSecretBackend do
    def encrypt(value), do: {:ok, "enc:" <> value}

    def decrypt("enc:" <> value), do: {:ok, value}
    def decrypt(_other), do: {:error, :invalid_ciphertext}
  end

  defmodule StreamingChatPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      payload = Jason.decode!(body)

      if payload["stream"] == true do
        stream_chat(conn)
      else
        # Chat-title generation and other one-shot requests stay non-streaming.
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "choices" => [%{"message" => %{"content" => "Story Time"}}],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
          })
        )
      end
    end

    defp stream_chat(conn) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      case Application.get_env(:bds, :chat_stream_scenario, :short) do
        :short -> stream_short(conn)
        :endless -> stream_endless(conn)
      end
    end

    defp stream_short(conn) do
      events =
        [
          delta_event(%{"content" => "Once"}),
          delta_event(%{"content" => " upon"}),
          delta_event(%{"content" => " a time"}),
          "data: " <>
            Jason.encode!(%{
              "choices" => [],
              "usage" => %{"prompt_tokens" => 9, "completion_tokens" => 4}
            }) <> "\n\n",
          "data: [DONE]\n\n"
        ]

      Enum.reduce_while(events, conn, fn event, conn ->
        case chunk(conn, event) do
          {:ok, conn} -> {:cont, conn}
          {:error, _reason} -> {:halt, conn}
        end
      end)
    end

    defp stream_endless(conn) do
      case chunk(conn, delta_event(%{"content" => "tick "})) do
        {:ok, conn} ->
          Process.sleep(50)
          stream_endless(conn)

        {:error, _reason} ->
          send(test_pid(), :sse_client_disconnected)
          conn
      end
    end

    defp delta_event(delta) do
      "data: " <> Jason.encode!(%{"choices" => [%{"delta" => delta}]}) <> "\n\n"
    end

    defp test_pid, do: Application.get_env(:bds, :chat_stream_test_pid)
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    Application.put_env(:bds, :chat_stream_test_pid, self())
    Application.put_env(:bds, :chat_stream_scenario, :short)

    original_chat = Application.fetch_env(:bds, :chat)

    Application.put_env(
      :bds,
      :chat,
      Keyword.merge(Application.get_env(:bds, :chat, []), stream_emit_interval_ms: 0)
    )

    on_exit(fn ->
      Application.delete_env(:bds, :chat_stream_scenario)

      case original_chat do
        {:ok, value} -> Application.put_env(:bds, :chat, value)
        :error -> Application.delete_env(:bds, :chat)
      end
    end)

    server = start_supervised!({Bandit, plug: StreamingChatPlug, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    assert {:ok, conversation} = BDS.AI.start_chat(%{model: "stream-model"})

    {:ok, conversation: conversation, streaming_port: port}
  end

  test "incremental content events arrive before the final reply and persistence matches", %{
    conversation: conversation,
    streaming_port: port
  } do
    conversation_id = conversation.id

    configure_streaming_runtime!(port)

    assert {:ok, reply} =
             BDS.AI.send_chat_message(conversation_id, "tell me a story",
               event_target: self(),
               secret_backend: FakeSecretBackend
             )

    assert reply.assistant_message.content == "Once upon a time"

    assert_received {:chat_streaming_content, ^conversation_id, "Once"}
    assert_received {:chat_streaming_content, ^conversation_id, "Once upon"}
    assert_received {:chat_streaming_content, ^conversation_id, "Once upon a time"}

    messages = BDS.AI.list_chat_messages(conversation_id)
    assistant_message = List.last(messages)
    assert assistant_message.role == :assistant
    assert assistant_message.content == "Once upon a time"
    assert assistant_message.token_usage_input == 9
    assert assistant_message.token_usage_output == 4
  end

  test "cancel_chat mid-stream aborts the HTTP request", %{
    conversation: conversation,
    streaming_port: port
  } do
    Application.put_env(:bds, :chat_stream_scenario, :endless)
    conversation_id = conversation.id
    test_pid = self()

    configure_streaming_runtime!(port)

    task =
      Task.async(fn ->
        BDS.AI.send_chat_message(conversation_id, "stream forever",
          event_target: test_pid,
          secret_backend: FakeSecretBackend
        )
      end)

    # Wait until tokens are actually flowing before cancelling.
    assert_receive {:chat_streaming_content, ^conversation_id, _content}, 2_000

    assert :ok = BDS.AI.cancel_chat(conversation_id)
    assert {:error, :cancelled} = Task.await(task)

    # The server notices the closed connection — the request was truly aborted.
    assert_receive :sse_client_disconnected, 2_000
  end

  defp configure_streaming_runtime!(port) do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(:online, %{
               url: "http://127.0.0.1:#{port}/v1",
               api_key: "sk-stream",
               model: "stream-model"
             }, secret_backend: FakeSecretBackend)

    assert :ok = BDS.AI.put_model_preference(:chat, "stream-model")
    assert :ok = BDS.AI.set_airplane_mode(false)
  end
end
