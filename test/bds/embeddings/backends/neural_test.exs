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

  describe "accelerator selection (NativeAcceleratedExecution)" do
    test "auto prefers Apple GPU (EMLX) when available on Apple Silicon" do
      assert Neural.select_accelerator(:auto, true, true) == :emlx
    end

    test "auto falls back to EXLA-CPU off Apple Silicon" do
      assert Neural.select_accelerator(:auto, true, false) == :exla
    end

    test "auto falls back to EXLA-CPU when EMLX is unavailable" do
      assert Neural.select_accelerator(:auto, false, true) == :exla
    end

    test "explicit :exla is honoured even on Apple Silicon with EMLX present" do
      assert Neural.select_accelerator(:exla, true, true) == :exla
    end

    test "explicit :emlx is honoured when available" do
      assert Neural.select_accelerator(:emlx, true, true) == :emlx
      assert Neural.select_accelerator(:emlx, true, false) == :emlx
    end

    test "explicit :emlx degrades to EXLA when EMLX is unavailable" do
      assert Neural.select_accelerator(:emlx, false, true) == :exla
    end

    test "defn options map each accelerator to its native compiler" do
      assert Neural.defn_options(:emlx) == [compiler: EMLX]
      assert Neural.defn_options(:exla) == [compiler: EXLA]
    end
  end
end
