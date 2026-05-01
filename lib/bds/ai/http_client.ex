defmodule BDS.AI.HttpClient do
  @moduledoc false

  def get(url, headers) when is_binary(url) and is_map(headers) do
    request =
      {String.to_charlist(url),
       Enum.map(headers, fn {key, value} ->
         {String.to_charlist(key), String.to_charlist(value)}
       end)}

    :inets.start()
    :ssl.start()

    case :httpc.request(:get, request, [], body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, body}} ->
        {:ok,
         %{
           status: status,
           headers: normalize_headers(response_headers),
           body: body
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def post(url, headers, body)
      when is_binary(url) and is_map(headers) and is_binary(body) do
    request =
      {String.to_charlist(url),
       Enum.map(headers, fn {key, value} ->
         {String.to_charlist(key), String.to_charlist(value)}
       end), ~c"application/json", body}

    :inets.start()
    :ssl.start()

    case :httpc.request(:post, request, [], body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok,
         %{
           status: status,
           headers: normalize_headers(response_headers),
           body: response_body
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_headers(headers) do
    Enum.into(headers, %{}, fn {key, value} ->
      {key |> to_string() |> String.downcase(), to_string(value)}
    end)
  end
end
