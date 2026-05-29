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

  Hardware acceleration follows the `NativeAcceleratedExecution` invariant.
  The serving's defn compiler is chosen at build time:

    * On Apple Silicon (arm64 macOS) with EMLX available, inference runs on the
      Apple GPU via MLX/Metal (`compiler: EMLX`, params placed on the
      `EMLX.Backend` GPU device).
    * Everywhere else — and as a fallback when EMLX is unavailable or explicitly
      disabled — it runs on optimised native CPU via XLA (`compiler: EXLA`).

  The accelerator can be pinned with `config :bds, :embeddings, accelerator:`
  to `:auto` (default), `:emlx`, or `:exla`.
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
  @default_accelerator :auto

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
    accelerator = current_accelerator()
    maybe_set_default_backend(accelerator)

    with {:ok, model_info} <- Bumblebee.load_model(repo),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer(repo) do
      serving =
        Bumblebee.Text.text_embedding(model_info, tokenizer,
          output_pool: :mean_pooling,
          output_attribute: :hidden_state,
          embedding_processor: :l2_norm,
          compile: [batch_size: batch_size(), sequence_length: sequence_length()],
          defn_options: defn_options(accelerator)
        )

      {:ok, serving}
    end
  end

  # Place model params/tensors on the Apple GPU (Metal) when accelerating with
  # EMLX so the compiled inference pass actually runs on-device. EXLA manages
  # its own device placement, so nothing to do there.
  defp maybe_set_default_backend(:emlx), do: Nx.global_default_backend({EMLX.Backend, device: :gpu})
  defp maybe_set_default_backend(:exla), do: :ok

  @doc false
  @spec defn_options(:emlx | :exla) :: keyword()
  def defn_options(:emlx), do: [compiler: EMLX]
  def defn_options(:exla), do: [compiler: EXLA]

  @doc false
  @spec current_accelerator() :: :emlx | :exla
  def current_accelerator do
    select_accelerator(configured_accelerator(), emlx_available?(), apple_silicon?())
  end

  @doc """
  Pure accelerator-selection policy for `NativeAcceleratedExecution`.

  Prefer the Apple GPU (EMLX) under `:auto` only when it is both available and
  running on Apple Silicon; honour an explicit `:emlx`/`:exla` request, but
  degrade a forced `:emlx` to EXLA when EMLX is not loaded so a misconfigured
  host still gets working CPU inference instead of crashing.
  """
  @spec select_accelerator(:auto | :emlx | :exla, boolean(), boolean()) :: :emlx | :exla
  def select_accelerator(:exla, _emlx_available?, _apple_silicon?), do: :exla
  def select_accelerator(:emlx, true, _apple_silicon?), do: :emlx
  def select_accelerator(:emlx, false, _apple_silicon?), do: :exla
  def select_accelerator(:auto, true, true), do: :emlx
  def select_accelerator(:auto, _emlx_available?, _apple_silicon?), do: :exla

  defp configured_accelerator do
    config() |> Keyword.get(:accelerator, @default_accelerator)
  end

  defp emlx_available? do
    Code.ensure_loaded?(EMLX) and Code.ensure_loaded?(EMLX.Backend)
  end

  defp apple_silicon? do
    :os.type() == {:unix, :darwin} and
      to_string(:erlang.system_info(:system_architecture)) =~ ~r/aarch64|arm/
  end

  defp batch_size do
    config() |> Keyword.get(:batch_size, @default_batch_size) |> max(1)
  end

  defp sequence_length do
    config() |> Keyword.get(:sequence_length, @default_sequence_length) |> max(1)
  end

  defp config, do: Application.get_env(:bds, :embeddings, [])
end
