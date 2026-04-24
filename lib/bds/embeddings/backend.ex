defmodule BDS.Embeddings.Backend do
  @moduledoc false

  @callback model_info() :: %{model_id: String.t(), dimensions: pos_integer()}
  @callback embed(String.t(), keyword()) :: {:ok, [number()]} | {:error, term()}
end
