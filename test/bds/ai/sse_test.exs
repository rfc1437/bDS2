defmodule BDS.AI.SSETest do
  use ExUnit.Case, async: true

  alias BDS.AI.SSE

  defp chunk_event(payload), do: "data: " <> Jason.encode!(payload) <> "\n\n"

  defp content_delta(text) do
    %{"choices" => [%{"delta" => %{"content" => text}}]}
  end

  test "assembles content from deltas across separate chunks" do
    sse = SSE.new(nil)

    sse =
      sse
      |> SSE.feed(chunk_event(content_delta("Hel")))
      |> SSE.feed(chunk_event(content_delta("lo ")))
      |> SSE.feed(chunk_event(content_delta("world")))
      |> SSE.feed("data: [DONE]\n\n")

    assert %{content: "Hello world", tool_calls: [], usage: nil} = SSE.finish(sse)
  end

  test "handles events split across arbitrary chunk boundaries" do
    raw =
      chunk_event(content_delta("alpha ")) <>
        chunk_event(content_delta("beta")) <> "data: [DONE]\n\n"

    # Feed the byte stream in 7-byte slices to exercise buffering.
    sse =
      raw
      |> :binary.bin_to_list()
      |> Enum.chunk_every(7)
      |> Enum.map(&:binary.list_to_bin/1)
      |> Enum.reduce(SSE.new(nil), &SSE.feed(&2, &1))

    assert %{content: "alpha beta"} = SSE.finish(sse)
  end

  test "supports CRLF line endings and data lines without a space" do
    payload = Jason.encode!(content_delta("crlf"))
    sse = SSE.feed(SSE.new(nil), "data:" <> payload <> "\r\n\r\ndata: [DONE]\r\n\r\n")

    assert %{content: "crlf"} = SSE.finish(sse)
  end

  test "ignores comments, other fields, and undecodable data" do
    sse =
      SSE.new(nil)
      |> SSE.feed(": keep-alive\n\n")
      |> SSE.feed("event: message\nid: 7\n" <> "data: " <> Jason.encode!(content_delta("ok")) <> "\n\n")
      |> SSE.feed("data: not-json\n\n")

    assert %{content: "ok"} = SSE.finish(sse)
  end

  test "stops processing after [DONE]" do
    sse =
      SSE.new(nil)
      |> SSE.feed(chunk_event(content_delta("kept")))
      |> SSE.feed("data: [DONE]\n\n")
      |> SSE.feed(chunk_event(content_delta(" dropped")))

    assert %{content: "kept"} = SSE.finish(sse)
  end

  test "finishes a trailing event that lacks the final blank line" do
    sse = SSE.feed(SSE.new(nil), "data: " <> Jason.encode!(content_delta("tail")))

    assert %{content: "tail"} = SSE.finish(sse)
  end

  test "content is nil when the stream carried no content" do
    sse = SSE.feed(SSE.new(nil), "data: [DONE]\n\n")

    assert %{content: nil} = SSE.finish(sse)
  end

  test "assembles tool calls from fragments in OpenAI wire shape" do
    fragments = [
      %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call-1",
                  "function" => %{"name" => "search_posts", "arguments" => ""}
                }
              ]
            }
          }
        ]
      },
      %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => "{\"query\":"}},
                %{
                  "index" => 1,
                  "id" => "call-2",
                  "function" => %{"name" => "count_posts", "arguments" => "{}"}
                }
              ]
            }
          }
        ]
      },
      %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\"sun\"}"}}]
            }
          }
        ]
      }
    ]

    sse = Enum.reduce(fragments, SSE.new(nil), &SSE.feed(&2, chunk_event(&1)))

    assert %{tool_calls: tool_calls} = SSE.finish(sse)

    assert tool_calls == [
             %{
               "id" => "call-1",
               "function" => %{"name" => "search_posts", "arguments" => ~s({"query":"sun"})}
             },
             %{"id" => "call-2", "function" => %{"name" => "count_posts", "arguments" => "{}"}}
           ]
  end

  test "captures usage from the final chunk" do
    sse =
      SSE.new(nil)
      |> SSE.feed(chunk_event(content_delta("hi")))
      |> SSE.feed(
        chunk_event(%{"choices" => [], "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 2}})
      )

    assert %{usage: %{"prompt_tokens" => 7, "completion_tokens" => 2}} = SSE.finish(sse)
  end

  test "emits cumulative content snapshots to the callback" do
    test_pid = self()
    sse = SSE.new(fn event -> send(test_pid, {:stream_event, event}) end, emit_interval_ms: 0)

    sse
    |> SSE.feed(chunk_event(content_delta("one")))
    |> SSE.feed(chunk_event(content_delta(" two")))

    assert_received {:stream_event, %{content: "one"}}
    assert_received {:stream_event, %{content: "one two"}}
  end

  test "throttles intermediate emissions but always emits the first delta" do
    test_pid = self()

    sse =
      SSE.new(fn event -> send(test_pid, {:stream_event, event}) end,
        emit_interval_ms: 60_000
      )

    sse
    |> SSE.feed(chunk_event(content_delta("first")))
    |> SSE.feed(chunk_event(content_delta(" second")))
    |> SSE.feed(chunk_event(content_delta(" third")))

    assert_received {:stream_event, %{content: "first"}}
    refute_received {:stream_event, _event}
  end

  test "tool-call-only streams emit no content events" do
    test_pid = self()

    sse =
      SSE.new(fn event -> send(test_pid, {:stream_event, event}) end, emit_interval_ms: 0)

    SSE.feed(
      sse,
      chunk_event(%{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "id" => "c", "function" => %{"name" => "n", "arguments" => "{}"}}
              ]
            }
          }
        ]
      })
    )

    refute_received {:stream_event, _event}
  end
end
