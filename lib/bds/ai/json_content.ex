defmodule BDS.AI.JsonContent do
  @moduledoc """
  Decodes JSON object payloads from model responses, tolerating the markdown
  code fences and surrounding prose that smaller (local) models often emit
  instead of bare JSON.
  """

  @fence_pattern ~r/```(?:json)?\s*\n?(.*?)```/is

  @spec decode(term()) :: map() | nil
  def decode(content) when is_binary(content) do
    decode_strict(content) || decode_fenced(content) || decode_embedded_object(content)
  end

  def decode(_content), do: nil

  defp decode_strict(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> nil
    end
  end

  defp decode_fenced(content) do
    case Regex.run(@fence_pattern, content, capture: :all_but_first) do
      [inner] -> decode_strict(String.trim(inner)) || decode_embedded_object(inner)
      _no_fence -> nil
    end
  end

  defp decode_embedded_object(content) do
    with {start, _length} <- :binary.match(content, "{"),
         [{last, _} | _] <- content |> :binary.matches("}") |> Enum.take(-1),
         true <- last > start do
      content
      |> binary_part(start, last - start + 1)
      |> decode_strict()
    else
      _no_object -> nil
    end
  end
end
