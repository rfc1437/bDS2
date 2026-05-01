defmodule BDS.AI do
  @moduledoc false

  alias BDS.AI.Catalog
  alias BDS.AI.Chat
  alias BDS.AI.OneShot
  alias BDS.AI.Runtime
  alias BDS.AI.SecretBackend
  alias BDS.MapUtils

  import BDS.AI.SettingsStore,
    only: [
      get_setting: 1,
      put_setting: 2,
      delete_setting: 1,
      put_secret: 3,
      get_secret: 2,
      encrypted_key: 1
    ]

  @typedoc "Endpoint kind such as :chat, :airplane_chat, :embedding, etc."
  @type endpoint_kind :: atom()

  @typedoc "Endpoint configuration map."
  @type endpoint :: %{
          kind: endpoint_kind(),
          url: String.t() | nil,
          api_key: String.t() | nil,
          model: String.t() | nil
        }

  @typedoc "Attribute map for endpoint operations."
  @type endpoint_attrs :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @spec put_endpoint(endpoint_kind(), endpoint_attrs(), keyword()) ::
          {:ok, endpoint()} | {:error, term()}
  def put_endpoint(kind, attrs, opts \\ [])
      when is_atom(kind) and is_map(attrs) and is_list(opts) do
    backend = Keyword.get(opts, :secret_backend, SecretBackend)
    kind_key = Atom.to_string(kind)

    url = MapUtils.attr(attrs, :url)
    model = MapUtils.attr(attrs, :model)
    api_key = MapUtils.attr(attrs, :api_key)

    with :ok <- put_setting("ai.#{kind_key}.url", url),
         :ok <- put_setting("ai.#{kind_key}.model", model),
         :ok <- put_secret("ai.#{kind_key}.api_key", api_key, backend) do
      {:ok, %{kind: kind, url: url, api_key: api_key, model: model}}
    end
  end

  @spec get_endpoint(endpoint_kind(), keyword()) ::
          {:ok, endpoint() | nil} | {:error, term()}
  def get_endpoint(kind, opts \\ []) when is_atom(kind) and is_list(opts) do
    backend = Keyword.get(opts, :secret_backend, SecretBackend)
    kind_key = Atom.to_string(kind)
    url = get_setting("ai.#{kind_key}.url")
    model = get_setting("ai.#{kind_key}.model")
    encrypted_api_key = get_setting(encrypted_key("ai.#{kind_key}.api_key"))

    cond do
      is_nil(url) and is_nil(model) and is_nil(encrypted_api_key) ->
        {:ok, nil}

      true ->
        with {:ok, api_key} <- get_secret(encrypted_api_key, backend) do
          {:ok, %{kind: kind, url: url, api_key: api_key, model: model}}
        end
    end
  end

  @spec delete_endpoint(endpoint_kind()) :: :ok
  def delete_endpoint(kind) when is_atom(kind) do
    kind_key = Atom.to_string(kind)
    delete_setting("ai.#{kind_key}.url")
    delete_setting("ai.#{kind_key}.model")
    delete_setting(encrypted_key("ai.#{kind_key}.api_key"))
    :ok
  end

  @spec list_endpoint_models(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_endpoint_models(endpoint, opts \\ []), to: Catalog

  @spec refresh_model_catalog(keyword()) ::
          {:ok, %{success: boolean(), models_updated: non_neg_integer(), not_modified: boolean()}}
          | {:error, term()}
  defdelegate refresh_model_catalog(opts \\ []), to: Catalog

  @spec list_catalog_providers() :: [map()]
  defdelegate list_catalog_providers(), to: Catalog

  @spec get_catalog_model(String.t(), String.t() | nil) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_catalog_model(model_id, provider_id \\ nil), to: Catalog

  @spec catalog_meta(String.t()) :: {:ok, String.t() | nil}
  defdelegate catalog_meta(key), to: Catalog

  @spec set_airplane_mode(boolean()) :: :ok | {:error, term()}
  def set_airplane_mode(enabled) when is_boolean(enabled) do
    put_setting("ai.airplane_mode_enabled", Atom.to_string(enabled))
  end

  @spec airplane_mode?(boolean()) :: boolean()
  def airplane_mode?(default \\ false) when is_boolean(default) do
    case get_setting("ai.airplane_mode_enabled") do
      nil -> default
      "false" -> false
      _other -> true
    end
  end

  @spec put_model_preference(atom(), String.t()) ::
          :ok | {:error, :unknown_model_preference | term()}
  def put_model_preference(key, model) when is_atom(key) and is_binary(model) do
    case Map.fetch(Runtime.model_preference_keys(), key) do
      {:ok, setting_key} -> put_setting(setting_key, model)
      :error -> {:error, :unknown_model_preference}
    end
  end

  @spec get_model_preference(atom()) ::
          {:ok, String.t() | nil} | {:error, :unknown_model_preference}
  def get_model_preference(key) when is_atom(key) do
    case Map.fetch(Runtime.model_preference_keys(), key) do
      {:ok, setting_key} -> {:ok, get_setting(setting_key)}
      :error -> {:error, :unknown_model_preference}
    end
  end

  @spec put_model_capabilities(String.t(), map()) :: :ok | {:error, term()}
  defdelegate put_model_capabilities(model_id, attrs), to: Catalog

  @spec detect_language(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate detect_language(text, opts \\ []), to: OneShot

  @spec analyze_taxonomy(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate analyze_taxonomy(post_input, opts \\ []), to: OneShot

  @spec analyze_import_taxonomy(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate analyze_import_taxonomy(import_terms, existing_terms, opts \\ []), to: OneShot

  @spec analyze_post(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate analyze_post(post_input, opts \\ []), to: OneShot

  @spec translate_post(map() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate translate_post(post_input, target_language, opts \\ []), to: OneShot

  @spec analyze_image(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate analyze_image(media_input, opts \\ []), to: OneShot

  @spec translate_media(map() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate translate_media(media_input, target_language, opts \\ []), to: OneShot

  @spec start_chat(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  defdelegate start_chat(attrs \\ %{}), to: Chat

  @spec list_chat_conversations() :: [map()]
  defdelegate list_chat_conversations(), to: Chat

  @spec get_chat_conversation(String.t()) :: BDS.AI.ChatConversation.t() | nil
  defdelegate get_chat_conversation(conversation_id), to: Chat

  @spec delete_chat_conversation(String.t()) :: {:ok, :deleted} | {:error, :not_found | term()}
  defdelegate delete_chat_conversation(conversation_id), to: Chat

  @spec available_chat_models(String.t() | nil) :: [map()]
  defdelegate available_chat_models(current_model \\ nil), to: Chat

  @spec set_conversation_model(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | Ecto.Changeset.t()}
  defdelegate set_conversation_model(conversation_id, model_id), to: Chat

  @spec list_chat_messages(String.t()) :: [map()]
  defdelegate list_chat_messages(conversation_id), to: Chat

  @spec send_chat_message(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | term()}
  defdelegate send_chat_message(conversation_id, content, opts \\ []), to: Chat

  @spec cancel_chat(String.t()) :: :ok
  defdelegate cancel_chat(conversation_id), to: Chat
end
