defmodule BDS.Embeddings.Backends.NeuralTest do
  use ExUnit.Case, async: false

  alias BDS.Embeddings.Backends.Neural

  setup do
    previous = Application.get_env(:bds, :embeddings)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:bds, :embeddings)
      else
        Application.put_env(:bds, :embeddings, previous)
      end
    end)

    :ok
  end

  test "reports the configured spec model id and dimensions without loading the model" do
    Application.put_env(:bds, :embeddings,
      backend: Neural,
      model_id: "Xenova/multilingual-e5-small",
      model_repo: "intfloat/multilingual-e5-small",
      dimensions: 384
    )

    assert %{model_id: "Xenova/multilingual-e5-small", dimensions: 384} = Neural.model_info()
  end

  test "implements the embeddings backend behaviour" do
    behaviours =
      Neural.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert BDS.Embeddings.Backend in behaviours
  end
end
