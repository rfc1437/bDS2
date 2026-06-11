defmodule BDS.AI.HttpClient do
  @moduledoc """
  Req-based HTTP client for AI endpoints.

  Replaces the previous `:httpc` wrapper with explicit connect/receive
  timeouts, TLS verification via Req's defaults, and transient retries for
  idempotent GETs only — POSTs (chat completions) are never retried.

  The response contract is unchanged: `{:ok, %{status, headers, body}}` with
  downcased single-valued header names and the body as a raw binary (callers
  decode JSON themselves), or `{:error, reason}` where transport failures
  surface as plain reason atoms such as `:timeout` or `:econnrefused`.

  Config (`config :bds, BDS.AI.HttpClient`):

    * `:connect_timeout_ms` — TCP/TLS connect budget (default 5_000)
    * `:receive_timeout_ms` — response budget (default 120_000; generous
      because local LLM completions are slow)
    * `:get_max_retries` — transient retries for GETs (default 2)
    * `:retry_delay_ms` — constant delay between retries (default 500)
  """

  @default_connect_timeout_ms 5_000
  @default_receive_timeout_ms 120_000
  @default_get_max_retries 2
  @default_retry_delay_ms 500

  @spec get(String.t(), %{String.t() => String.t()}) ::
          {:ok, %{status: non_neg_integer(), headers: map(), body: binary()}} | {:error, term()}
  def get(url, headers) when is_binary(url) and is_map(headers) do
    [
      method: :get,
      url: url,
      headers: headers,
      retry: :transient,
      max_retries: config(:get_max_retries, @default_get_max_retries),
      retry_delay: fn _retry_count -> config(:retry_delay_ms, @default_retry_delay_ms) end,
      retry_log_level: false
    ]
    |> Keyword.merge(base_options())
    |> Req.request()
    |> normalize_result()
  end

  @spec post(String.t(), %{String.t() => String.t()}, binary()) ::
          {:ok, %{status: non_neg_integer(), headers: map(), body: binary()}} | {:error, term()}
  def post(url, headers, body)
      when is_binary(url) and is_map(headers) and is_binary(body) do
    [
      method: :post,
      url: url,
      headers: headers,
      body: body,
      # Completions are not idempotent; a retry could bill or generate twice.
      retry: false
    ]
    |> Keyword.merge(base_options())
    |> Req.request()
    |> normalize_result()
  end

  @doc """
  Streaming POST: body chunks of a 200 response are folded into `acc` via
  `reducer.(chunk, acc)` as they arrive; non-200 bodies are collected whole
  for error reporting. Returns the final accumulator alongside the response.

  Never retried (same reasoning as `post/3`), and `accept-encoding` is
  disabled so event-stream chunks arrive uncompressed. The request runs in
  the calling process — killing that process aborts the underlying
  connection, which is what makes mid-stream chat cancellation work.
  """
  @spec post_stream(String.t(), %{String.t() => String.t()}, binary(), acc, (binary(), acc ->
                                                                               acc)) ::
          {:ok, %{status: non_neg_integer(), headers: map(), body: binary()}, acc}
          | {:error, term()}
        when acc: term()
  def post_stream(url, headers, body, acc, reducer)
      when is_binary(url) and is_map(headers) and is_binary(body) and is_function(reducer, 2) do
    into = fn {:data, data}, {req, resp} ->
      resp =
        if resp.status == 200 do
          next_acc = reducer.(data, Req.Response.get_private(resp, :bds_stream_acc, acc))
          Req.Response.put_private(resp, :bds_stream_acc, next_acc)
        else
          %{resp | body: collected_body(resp.body) <> data}
        end

      {:cont, {req, resp}}
    end

    [
      method: :post,
      url: url,
      headers: headers,
      body: body,
      retry: false,
      compressed: false,
      into: into
    ]
    |> Keyword.merge(base_options())
    |> Req.request()
    |> case do
      {:ok, %Req.Response{} = resp} ->
        {:ok, %{status: resp.status, headers: normalize_headers(resp.headers), body: collected_body(resp.body)},
         Req.Response.get_private(resp, :bds_stream_acc, acc)}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collected_body(body) when is_binary(body), do: body
  defp collected_body(_body), do: ""

  defp base_options do
    [
      connect_options: [timeout: config(:connect_timeout_ms, @default_connect_timeout_ms)],
      receive_timeout: config(:receive_timeout_ms, @default_receive_timeout_ms),
      # Callers parse the body themselves; keep it a raw binary.
      decode_body: false
    ]
  end

  defp normalize_result({:ok, %Req.Response{status: status, headers: headers, body: body}}) do
    {:ok, %{status: status, headers: normalize_headers(headers), body: body}}
  end

  defp normalize_result({:error, %Req.TransportError{reason: reason}}), do: {:error, reason}
  defp normalize_result({:error, reason}), do: {:error, reason}

  # Req header names are already downcased; values arrive as lists.
  defp normalize_headers(headers) do
    Map.new(headers, fn {name, values} -> {name, Enum.join(List.wrap(values), ", ")} end)
  end

  defp config(key, default) do
    Application.get_env(:bds, __MODULE__, []) |> Keyword.get(key, default)
  end
end
