defmodule BDS.AI.Catalog do
  @moduledoc false

  import Ecto.Query
  import BDS.AI.SettingsStore,
    only: [
      get_setting: 1,
      put_setting: 2,
      get_catalog_meta_value: 1,
      put_catalog_meta: 2
    ]

  alias BDS.AI.CatalogProvider
  alias BDS.AI.Model
  alias BDS.AI.ModelModality
  alias BDS.AI.OpenAICompatibleRuntime
  alias BDS.Persistence
  alias BDS.Repo

  @catalog_url "https://models.dev/api.json"

  @spec list_endpoint_models(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_endpoint_models(endpoint, opts \\ []) when is_map(endpoint) and is_list(opts) do
    http_client = Keyword.get(opts, :http_client, Application.get_env(:bds, :ai_http_client, BDS.AI.HttpClient))
    OpenAICompatibleRuntime.list_models(endpoint, http_client: http_client)
  end

  @spec refresh_model_catalog(keyword()) ::
          {:ok, %{success: boolean(), models_updated: non_neg_integer(), not_modified: boolean()}}
          | {:error, term()}
  def refresh_model_catalog(opts \\ []) when is_list(opts) do
    http_client = Keyword.get(opts, :http_client, BDS.AI.HttpClient)

    headers =
      %{"accept" => "application/json"}
      |> maybe_put_header("if-none-match", get_catalog_meta_value("etag"))

    with {:ok, response} <- http_get(http_client, @catalog_url, headers) do
      case response.status do
        304 ->
          :ok = put_catalog_meta("last_fetched_at", DateTime.utc_now() |> DateTime.to_iso8601())
          {:ok, %{success: true, models_updated: 0, not_modified: true}}

        200 ->
          payload = Jason.decode!(response.body)
          models_updated = persist_catalog(payload)

          if etag = response.headers["etag"] do
            :ok = put_catalog_meta("etag", etag)
          end

          :ok = put_catalog_meta("last_fetched_at", DateTime.utc_now() |> DateTime.to_iso8601())

          {:ok, %{success: true, models_updated: models_updated, not_modified: false}}

        status ->
          {:error, %{kind: :http_error, status: status}}
      end
    end
  end

  @spec list_catalog_providers() :: [map()]
  def list_catalog_providers do
    Repo.all(from(provider in CatalogProvider, order_by: [asc: provider.id]))
    |> Enum.map(fn provider ->
      %{
        id: provider.id,
        name: provider.name,
        env_keys: decode_json_list(provider.env_keys),
        package_ref: provider.package_ref,
        api_url: provider.api_url,
        doc_url: provider.doc_url,
        updated_at: provider.updated_at
      }
    end)
  end

  @spec get_catalog_model(String.t(), String.t() | nil) :: {:ok, map()} | {:error, :not_found}
  def get_catalog_model(model_id, provider_id \\ nil) when is_binary(model_id) do
    query =
      from(model in Model,
        where: model.model_id == ^model_id,
        order_by: [asc: model.provider]
      )

    query =
      case provider_id do
        nil -> query
        provider -> from(model in query, where: model.provider == ^provider)
      end

    case Repo.one(query) do
      nil -> {:error, :not_found}
      model -> {:ok, format_model(model)}
    end
  end

  @spec catalog_meta(String.t()) :: {:ok, String.t() | nil}
  def catalog_meta(key) when is_binary(key) do
    {:ok, get_catalog_meta_value(key)}
  end

  @spec put_model_capabilities(String.t(), map()) :: :ok | {:error, term()}
  def put_model_capabilities(model_id, attrs) when is_binary(model_id) and is_map(attrs) do
    capabilities = %{
      supports_attachment: truthy?(Map.get(attrs, :supports_attachment) || Map.get(attrs, "supports_attachment")),
      supports_tool_calls: truthy?(Map.get(attrs, :supports_tool_calls) || Map.get(attrs, "supports_tool_calls"))
    }

    put_setting("ai.model_capabilities.#{model_id}", Jason.encode!(capabilities))
  end

  @spec format_model(map()) :: map()
  def format_model(model) do
    modalities =
      Repo.all(
        from(modality in ModelModality,
          where: modality.provider == ^model.provider and modality.model_id == ^model.model_id
        )
      )

    %{
      provider: model.provider,
      model_id: model.model_id,
      name: model.name,
      family: model.family,
      supports_attachment: model.supports_attachment,
      supports_reasoning: model.supports_reasoning,
      supports_tool_calls: model.supports_tool_calls,
      supports_structured_output: model.supports_structured_output,
      supports_temperature: model.supports_temperature,
      knowledge: model.knowledge,
      release_date: model.release_date,
      last_updated_date: model.last_updated_date,
      open_weights: model.open_weights,
      input_price: model.input_price,
      output_price: model.output_price,
      cache_read_price: model.cache_read_price,
      cache_write_price: model.cache_write_price,
      context_window: model.context_window,
      max_input_tokens: model.max_input_tokens,
      max_output_tokens: model.max_output_tokens,
      interleaved: model.interleaved,
      status: model.status,
      updated_at: model.updated_at,
      input_modalities:
        modalities
        |> Enum.filter(&(&1.direction == :input))
        |> Enum.map(&Atom.to_string(&1.modality)),
      output_modalities:
        modalities
        |> Enum.filter(&(&1.direction == :output))
        |> Enum.map(&Atom.to_string(&1.modality))
    }
  end

  @spec model_capabilities(String.t()) :: %{supports_attachment: boolean(), supports_tool_calls: boolean()}
  def model_capabilities(model_id) do
    overrides = decode_model_capabilities_override(model_id)

    from_catalog =
      case get_catalog_model(model_id) do
        {:ok, model} ->
          %{
            supports_attachment: model.supports_attachment or ("image" in model.input_modalities),
            supports_tool_calls: model.supports_tool_calls
          }

        _other ->
          inferred_model_capabilities(model_id)
      end

    Map.merge(from_catalog, overrides)
  end

  @spec decode_nullable_json(nil | binary()) :: any()
  def decode_nullable_json(nil), do: nil
  def decode_nullable_json(value) when is_binary(value), do: Jason.decode!(value)

  defp inferred_model_capabilities(model_id) do
    normalized = String.downcase(model_id)

    %{
      supports_attachment:
        String.contains?(normalized, "4o") or String.contains?(normalized, "vision") or
          String.contains?(normalized, "llava"),
      supports_tool_calls:
        String.contains?(normalized, "gpt") or String.contains?(normalized, "claude") or
          String.contains?(normalized, "tool")
    }
  end

  defp decode_model_capabilities_override(model_id) do
    case get_setting("ai.model_capabilities.#{model_id}") do
      nil -> %{}
      value -> Jason.decode!(value) |> atomize_map_keys()
    end
  end

  defp atomize_map_keys(map) do
    Enum.into(map, %{}, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp persist_catalog(payload) do
    now = Persistence.now_ms()

    Repo.transaction(fn ->
      Repo.delete_all(ModelModality)
      Repo.delete_all(Model)
      Repo.delete_all(CatalogProvider)

      Enum.reduce(payload, 0, fn {provider_id, provider_data}, count ->
        provider_attrs = %{
          id: provider_id,
          name: Map.get(provider_data, "name", provider_id),
          env_keys: Jason.encode!(Map.get(provider_data, "env", [])),
          package_ref: Map.get(provider_data, "npm"),
          api_url: Map.get(provider_data, "api"),
          doc_url: Map.get(provider_data, "doc"),
          updated_at: now
        }

        %CatalogProvider{}
        |> CatalogProvider.changeset(provider_attrs)
        |> Repo.insert!()

        models = Map.get(provider_data, "models", %{})

        Enum.reduce(models, count, fn {model_id, model_data}, inner_count ->
          model_attrs = %{
            provider: provider_id,
            model_id: model_id,
            name: Map.get(model_data, "name", model_id),
            family: Map.get(model_data, "family"),
            supports_attachment: Map.get(model_data, "attachment", false),
            supports_reasoning: Map.get(model_data, "reasoning", false),
            supports_tool_calls: Map.get(model_data, "tool_call", false),
            supports_structured_output: Map.get(model_data, "structured_output", false),
            supports_temperature: Map.get(model_data, "temperature", false),
            knowledge: Map.get(model_data, "knowledge"),
            release_date: Map.get(model_data, "release_date"),
            last_updated_date: Map.get(model_data, "last_updated"),
            open_weights: Map.get(model_data, "open_weights", false),
            input_price: get_in(model_data, ["cost", "input"]),
            output_price: get_in(model_data, ["cost", "output"]),
            cache_read_price: get_in(model_data, ["cost", "cache_read"]),
            cache_write_price: get_in(model_data, ["cost", "cache_write"]),
            context_window: get_in(model_data, ["limit", "context"]) || 0,
            max_input_tokens: get_in(model_data, ["limit", "input"]) || 0,
            max_output_tokens: get_in(model_data, ["limit", "output"]) || 0,
            interleaved: encode_nullable(Map.get(model_data, "interleaved")),
            status: Map.get(model_data, "status"),
            updated_at: now
          }

          %Model{}
          |> Model.changeset(model_attrs)
          |> Repo.insert!()

          insert_modalities(provider_id, model_id, Map.get(model_data, "input_modalities", []), :input)
          insert_modalities(provider_id, model_id, Map.get(model_data, "output_modalities", []), :output)

          inner_count + 1
        end)
      end)
    end)
    |> case do
      {:ok, count} -> count
      {:error, reason} -> raise reason
    end
  end

  defp insert_modalities(provider_id, model_id, modalities, direction) do
    Enum.each(modalities, fn modality ->
      %ModelModality{}
      |> ModelModality.changeset(%{
        provider: provider_id,
        model_id: model_id,
        direction: direction,
        modality: parse_modality(modality)
      })
      |> Repo.insert!()
    end)
  end

  defp parse_modality("text"), do: :text
  defp parse_modality("image"), do: :image
  defp parse_modality("audio"), do: :audio
  defp parse_modality("file"), do: :file
  defp parse_modality("tool"), do: :tool
  defp parse_modality(other) when is_binary(other), do: String.to_atom(other)

  defp encode_nullable(nil), do: nil
  defp encode_nullable(value), do: Jason.encode!(value)

  defp http_get(client, url, headers) when is_atom(client), do: client.get(url, headers)
  defp http_get(client, url, headers) when is_function(client, 2), do: client.(url, headers)

  defp maybe_put_header(headers, _key, nil), do: headers
  defp maybe_put_header(headers, key, value), do: Map.put(headers, key, value)

  defp decode_json_list(nil), do: []
  defp decode_json_list(value), do: Jason.decode!(value)

  defp truthy?(value), do: value in [true, "true", 1, "1"]
end
