defmodule BDS.Embeddings.Backends.Neural do
  @moduledoc """
  Real on-device neural embedding backend.

  Implements the `RealNeuralModel` and `ModelCaching` invariants from
  `specs/embedding.allium`: embeddings are produced by the actual
  multilingual-e5-small transformer (the `intfloat/multilingual-e5-small`
  weights behind the `Xenova/multilingual-e5-small` identifier) via
  Bumblebee + EXLA, never by a lexical approximation.

    * Lazy-loaded — the model pipeline is built on the first embedding
      request, not at application startup.
    * Model files (~100 MB) are downloaded from the Hugging Face Hub on
      first use and cached on disk (Bumblebee cache dir), persisting across
      sessions and project switches.
    * Text preprocessing follows the e5 convention: every input is prefixed
      with `"query: "`, pooled with mean pooling over the attention mask, and
      L2-normalised. This is what makes cross-language semantic similarity
      work.
    * Inference is batched. `embed_many/2` runs the model on `batch_size`
      texts per compiled inference run instead of one at a time, which is the
      dominant cost when (re)indexing large numbers of posts. The serving is
      compiled for a fixed `batch_size`/`sequence_length` (configurable);
      shorter sequences mean less wasted transformer compute.

  EXLA on Apple Silicon runs on the CPU — XLA has no Metal/GPU backend. See
  SPECGAPS A1-14c for the planned EMLX (Apple GPU via MLX) acceleration path.
  """

  @behaviour BDS.Embeddings.Backend

  use GenServer

  @query_prefix "query: "
  @embed_timeout :timer.minutes(10)

  @default_model_id "Xenova/multilingual-e5-small"
  @default_model_repo "intfloat/multilingual-e5-small"
  @default_dimensions 384
  @default_batch_size 16
  @default_sequence_length 256

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl BDS.Embeddings.Backend
  def model_info do
    config = config()

    %{
      model_id: Keyword.get(config, :model_id, @default_model_id),
      dimensions: Keyword.get(config, :dimensions, @default_dimensions)
    }
  end

  @impl BDS.Embeddings.Backend
  def embed(text, _opts) when is_binary(text) do
    case run([@query_prefix <> text]) do
      {:ok, [vector]} -> {:ok, vector}
      {:ok, _other} -> {:error, :unexpected_embedding_result}
      {:error, _reason} = error -> error
    end
  end

  @impl BDS.Embeddings.Backend
  def embed_many([], _opts), do: {:ok, []}

  def embed_many(texts, _opts) when is_list(texts) do
    run(Enum.map(texts, &(@query_prefix <> &1)))
  end

  defp run(prefixed_texts) do
    GenServer.call(__MODULE__, {:embed, prefixed_texts}, @embed_timeout)
  catch
    :exit, reason -> {:error, {:embedding_backend_unavailable, reason}}
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{serving: nil}}

  @impl GenServer
  def handle_call({:embed, texts}, _from, state) do
    case ensure_serving(state) do
      {:ok, %{serving: serving} = next_state} ->
        vectors =
          texts
          |> Enum.chunk_every(batch_size())
          |> Enum.flat_map(&run_chunk(serving, &1))

        {:reply, {:ok, vectors}, next_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  rescue
    exception ->
      {:reply, {:error, Exception.message(exception)}, state}
  end

  defp run_chunk(serving, [single]) do
    %{embedding: tensor} = Nx.Serving.run(serving, single)
    [Nx.to_flat_list(tensor)]
  end

  defp run_chunk(serving, chunk) do
    serving
    |> Nx.Serving.run(chunk)
    |> Enum.map(fn %{embedding: tensor} -> Nx.to_flat_list(tensor) end)
  end

  defp ensure_serving(%{serving: nil} = state) do
    case build_serving() do
      {:ok, serving} -> {:ok, %{state | serving: serving}}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_serving(state), do: {:ok, state}

  defp build_serving do
    repo = {:hf, Keyword.get(config(), :model_repo, @default_model_repo)}

    with {:ok, model_info} <- Bumblebee.load_model(repo),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(repo) do
      serving =
        Bumblebee.Text.text_embedding(model_info, tokenizer,
          output_pool: :mean_pooling,
          output_attribute: :hidden_state,
          embedding_processor: :l2_norm,
          compile: [batch_size: batch_size(), sequence_length: sequence_length()],
          defn_options: [compiler: EXLA]
        )

      {:ok, serving}
    end
  end

  defp batch_size do
    config() |> Keyword.get(:batch_size, @default_batch_size) |> max(1)
  end

  defp sequence_length do
    config() |> Keyword.get(:sequence_length, @default_sequence_length) |> max(1)
  end

  defp config, do: Application.get_env(:bds, :embeddings, [])
end
