defmodule BDS.AI.Runtime do
  @moduledoc false

  alias BDS.AI
  alias BDS.AI.Catalog
  alias BDS.AI.SecretBackend

  @model_preference_keys %{
    default: "ai.model.default",
    chat: "ai.model.chat",
    title: "ai.model.title",
    image_analysis: "ai.model.image_analysis",
    airplane_chat: "ai.airplane.model.chat",
    airplane_title: "ai.airplane.model.title",
    airplane_image_analysis: "ai.airplane.model.image_analysis"
  }

  @spec model_preference_keys() :: %{atom() => String.t()}
  def model_preference_keys, do: @model_preference_keys

  @spec resolve_target(atom(), keyword()) ::
          {:ok, map(), String.t(), :airplane | :online} | {:error, term()}
  def resolve_target(operation, extra) do
    mode = if AI.airplane_mode?(), do: :airplane, else: :online
    secret_backend = Keyword.get(extra, :secret_backend, SecretBackend)

    with {:ok, endpoint} <- fetch_endpoint_for_mode(mode, secret_backend),
         {:ok, model} <- resolve_model_for_operation(operation, mode, endpoint, extra) do
      {:ok, endpoint, model, mode}
    end
  end

  @spec validate_target(atom(), String.t(), :airplane | :online) :: :ok | {:error, term()}
  def validate_target(:analyze_image, model, _mode) do
    if Catalog.model_capabilities(model).supports_attachment do
      :ok
    else
      {:error, %{kind: :model_capability_missing, capability: :supports_attachment, model: model}}
    end
  end

  def validate_target(_operation, _model, _mode), do: :ok

  @spec endpoint_with_model(map(), String.t()) :: map()
  def endpoint_with_model(endpoint, model), do: Map.put(endpoint, :model, model)

  @spec model_preference_value(atom()) :: String.t() | nil
  def model_preference_value(key) do
    case AI.get_model_preference(key) do
      {:ok, value} -> value
      _other -> nil
    end
  end

  defp resolve_model_for_operation(:chat, :airplane, endpoint, _extra) do
    {:ok, model_preference_value(:airplane_chat) || endpoint.model}
  end

  defp resolve_model_for_operation(:chat, :online, endpoint, conversation: conversation) do
    {:ok, conversation.model || model_preference_value(:chat) || endpoint.model}
  end

  defp resolve_model_for_operation(:chat, :online, endpoint, _extra) do
    {:ok, model_preference_value(:chat) || endpoint.model}
  end

  defp resolve_model_for_operation(:analyze_image, :airplane, endpoint, extra) do
    {:ok, Keyword.get(extra, :model) || model_preference_value(:airplane_image_analysis) || endpoint.model}
  end

  defp resolve_model_for_operation(:analyze_image, :online, endpoint, extra) do
    {:ok, Keyword.get(extra, :model) || model_preference_value(:image_analysis) || endpoint.model}
  end

  defp resolve_model_for_operation(_operation, :airplane, endpoint, extra) do
    {:ok, Keyword.get(extra, :model) || model_preference_value(:airplane_title) || endpoint.model}
  end

  defp resolve_model_for_operation(_operation, :online, endpoint, extra) do
    {:ok, Keyword.get(extra, :model) || model_preference_value(:title) || endpoint.model}
  end

  defp fetch_endpoint_for_mode(mode, secret_backend) do
    with {:ok, endpoint} <- AI.get_endpoint(mode, secret_backend: secret_backend) do
      case endpoint do
        %{url: url, model: model} = loaded when is_binary(url) and url != "" and is_binary(model) and model != "" ->
          if mode == :online and blank?(loaded.api_key) do
            {:error, %{kind: :endpoint_not_configured, endpoint: mode}}
          else
            {:ok, loaded}
          end

        _other ->
          {:error, %{kind: :endpoint_not_configured, endpoint: mode}}
      end
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
