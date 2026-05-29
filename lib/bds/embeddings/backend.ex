defmodule BDS.Embeddings.Backend do
  @moduledoc false

  @callback model_info() :: %{model_id: String.t(), dimensions: pos_integer()}
  @callback embed(String.t(), keyword()) :: {:ok, [number()]} | {:error, term()}

  @doc """
  Embeds a list of texts in a single call.

  Backends that can amortise work across inputs (e.g. running the neural model
  on a batched tensor) should implement this. The result list is aligned with
  the input list. Optional — callers fall back to repeated `embed/2`.
  """
  @callback embed_many([String.t()], keyword()) :: {:ok, [[number()]]} | {:error, term()}

  @optional_callbacks embed_many: 2
end
