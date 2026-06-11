defmodule BDS.AI.SSE do
  @moduledoc """
  Incremental assembler for OpenAI-compatible `text/event-stream` chat
  completions.

  Fed raw transport chunks via `feed/2`, it buffers partial events, decodes
  `data:` payloads, and accumulates content deltas, tool-call fragments, and
  usage. Content is reported to the optional `on_event` callback as
  **cumulative snapshots** (`%{content: binary}`) — replace semantics, which
  matches how the chat editor renders streaming state and resets naturally
  between tool rounds. Emissions are throttled to `:emit_interval_ms`
  (the first delta always emits immediately for perceived latency).

  `finish/1` returns the assembled message in OpenAI wire shape so the
  runtime can reuse its non-streaming normalization:
  `%{content: binary | nil, tool_calls: [%{"id" => _, "function" => %{"name" => _, "arguments" => json_string}}], usage: map | nil}`.
  """

  defstruct buffer: "",
            raw: [],
            content: [],
            content?: false,
            tool_calls: %{},
            usage: nil,
            done?: false,
            on_event: nil,
            emit_interval_ms: 100,
            last_emit_at: nil

  @type t :: %__MODULE__{}

  @spec new((map() -> any()) | nil, keyword()) :: t()
  def new(on_event \\ nil, opts \\ []) when is_list(opts) do
    %__MODULE__{
      on_event: on_event,
      emit_interval_ms: Keyword.get(opts, :emit_interval_ms, 100)
    }
  end

  @spec feed(t(), binary()) :: t()
  def feed(%__MODULE__{done?: true} = sse, _chunk), do: sse

  def feed(%__MODULE__{} = sse, chunk) when is_binary(chunk) do
    sse = %{sse | raw: [chunk | sse.raw]}
    parts = String.split(sse.buffer <> chunk, ~r/\r?\n\r?\n/)
    {complete_events, [rest]} = Enum.split(parts, -1)

    Enum.reduce(complete_events, %{sse | buffer: rest}, &process_event(&2, &1))
  end

  @doc """
  The unparsed transport bytes, for callers that discover after the fact
  that the response was not an event stream (e.g. a provider that ignored
  the `stream` flag and answered with plain JSON).
  """
  @spec raw_body(t()) :: binary()
  def raw_body(%__MODULE__{} = sse) do
    sse.raw |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @spec finish(t()) :: %{content: binary() | nil, tool_calls: [map()], usage: map() | nil}
  def finish(%__MODULE__{} = sse) do
    # A final event may arrive without its trailing blank line.
    sse =
      case String.trim(sse.buffer) do
        "" -> sse
        remnant -> process_event(%{sse | buffer: ""}, remnant)
      end

    %{
      content: assembled_content(sse),
      tool_calls: assembled_tool_calls(sse),
      usage: sse.usage
    }
  end

  defp process_event(%{done?: true} = sse, _event), do: sse

  defp process_event(sse, event) do
    data =
      event
      |> String.split(~r/\r?\n/)
      |> Enum.flat_map(&data_line/1)
      |> Enum.join("\n")

    cond do
      data == "" ->
        sse

      String.trim(data) == "[DONE]" ->
        %{sse | done?: true}

      true ->
        case Jason.decode(data) do
          {:ok, payload} when is_map(payload) -> apply_payload(sse, payload)
          _other -> sse
        end
    end
  end

  defp data_line("data: " <> rest), do: [rest]
  defp data_line("data:" <> rest), do: [rest]
  defp data_line(_line), do: []

  defp apply_payload(sse, payload) do
    delta = get_in(payload, ["choices", Access.at(0), "delta"]) || %{}

    sse
    |> apply_content(delta["content"])
    |> apply_tool_calls(delta["tool_calls"])
    |> apply_usage(payload["usage"])
  end

  defp apply_content(sse, content) when is_binary(content) and content != "" do
    %{sse | content: [content | sse.content], content?: true}
    |> maybe_emit()
  end

  defp apply_content(sse, _content), do: sse

  defp apply_tool_calls(sse, [_ | _] = fragments) do
    Enum.reduce(fragments, sse, fn fragment, acc ->
      index = fragment["index"] || 0
      existing = Map.get(acc.tool_calls, index, %{id: nil, name: nil, arguments: []})
      function_part = fragment["function"] || %{}

      merged = %{
        id: existing.id || fragment["id"],
        name: existing.name || function_part["name"],
        arguments: [existing.arguments, function_part["arguments"] || ""]
      }

      %{acc | tool_calls: Map.put(acc.tool_calls, index, merged)}
    end)
  end

  defp apply_tool_calls(sse, _fragments), do: sse

  defp apply_usage(sse, usage) when is_map(usage) and map_size(usage) > 0,
    do: %{sse | usage: usage}

  defp apply_usage(sse, _usage), do: sse

  defp maybe_emit(%{on_event: nil} = sse), do: sse

  defp maybe_emit(sse) do
    now = System.monotonic_time(:millisecond)

    if is_nil(sse.last_emit_at) or now - sse.last_emit_at >= sse.emit_interval_ms do
      sse.on_event.(%{content: assembled_content(sse) || ""})
      %{sse | last_emit_at: now}
    else
      sse
    end
  end

  defp assembled_content(%{content?: false}), do: nil

  defp assembled_content(sse) do
    sse.content |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp assembled_tool_calls(sse) do
    sse.tool_calls
    |> Enum.sort_by(fn {index, _tool_call} -> index end)
    |> Enum.map(fn {_index, tool_call} ->
      %{
        "id" => tool_call.id,
        "function" => %{
          "name" => tool_call.name,
          "arguments" => IO.iodata_to_binary(tool_call.arguments)
        }
      }
    end)
  end
end
