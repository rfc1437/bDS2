defmodule BDS.Embeddings.Backends.InApp do
  @moduledoc """
  Deterministic lexical embedding stub.

  This backend does NOT satisfy the `RealNeuralModel` invariant — it projects
  stemmed tokens and bigrams into a sparse hashed vector. It exists only as an
  offline, dependency-free fallback for tests and environments where the neural
  model (see `BDS.Embeddings.Backends.Neural`) cannot be loaded. Production and
  development use the neural backend.
  """

  @behaviour BDS.Embeddings.Backend

  @impl true
  def model_info do
    config = Application.get_env(:bds, :embeddings, [])

    %{
      model_id: Keyword.get(config, :model_id, "Xenova/multilingual-e5-small"),
      dimensions: Keyword.get(config, :dimensions, 384)
    }
  end

  @impl true
  def embed(text, opts) when is_binary(text) and is_list(opts) do
    language = Keyword.get(opts, :language)
    dimensions = model_info().dimensions

    vector =
      text
      |> BDS.Search.stem(language)
      |> tokenize()
      |> weighted_terms()
      |> project_to_vector(dimensions)
      |> normalize()

    {:ok, vector}
  end

  @impl true
  def embed_many(texts, opts) when is_list(texts) and is_list(opts) do
    vectors =
      Enum.map(texts, fn text ->
        {:ok, vector} = embed(text, opts)
        vector
      end)

    {:ok, vectors}
  end

  defp tokenize(text) do
    Regex.scan(~r/[[:alnum:]]+/u, String.downcase(text))
    |> List.flatten()
  end

  defp weighted_terms(tokens) do
    bigrams = tokens |> Enum.chunk_every(2, 1, :discard) |> Enum.map(&Enum.join(&1, "::"))
    tokens ++ bigrams
  end

  defp project_to_vector(terms, dimensions) do
    terms
    |> Enum.reduce(:array.new(dimensions, default: 0.0), fn term, acc ->
      index = :erlang.phash2(term, dimensions)
      :array.set(index, :array.get(index, acc) + 1.0, acc)
    end)
    |> :array.to_list()
  end

  defp normalize(vector) do
    norm = :math.sqrt(Enum.reduce(vector, 0.0, fn value, acc -> acc + value * value end))

    if norm == 0.0 do
      vector
    else
      Enum.map(vector, &(&1 / norm))
    end
  end
end
