defmodule BDS.Desktop.ShellLive.SettingsEditor.AISettings do
  @moduledoc false

  use Phoenix.Component

  alias BDS.AI
  alias BDS.Desktop.ShellLive.Notify
  alias BDS.Desktop.ShellLive.SettingsEditor.EditorSettings
  require Logger
  use Gettext, backend: BDS.Gettext

  @spec ai_form(term()) :: term()
  def ai_form(assigns) do
    online_endpoint = safe_endpoint(:online)
    airplane_endpoint = safe_endpoint(:airplane)

    %{
      "online_url" => Map.get(online_endpoint || %{}, :url, ""),
      "online_api_key" => Map.get(online_endpoint || %{}, :api_key, ""),
      "online_chat_model" =>
        get_model_preference(:chat) || Map.get(online_endpoint || %{}, :model, ""),
      "online_chat_tools" =>
        model_supports_tool_calls?(
          get_model_preference(:chat) || Map.get(online_endpoint || %{}, :model, "")
        ),
      "online_chat_disable_reasoning" =>
        model_disables_reasoning?(
          get_model_preference(:chat) || Map.get(online_endpoint || %{}, :model, "")
        ),
      "online_title_model" => get_model_preference(:title) || "",
      "online_image_analysis_model" => get_model_preference(:image_analysis) || "",
      "online_chat_images" => model_supports_images?(get_model_preference(:image_analysis)),
      "offline_url" => Map.get(airplane_endpoint || %{}, :url, ""),
      "offline_api_key" => Map.get(airplane_endpoint || %{}, :api_key, ""),
      "offline_mode" => Map.get(assigns, :offline_mode, AI.airplane_mode?(true)),
      "offline_chat_model" =>
        get_model_preference(:airplane_chat) ||
          Map.get(airplane_endpoint || %{}, :model, ""),
      "offline_chat_tools" =>
        model_supports_tool_calls?(
          get_model_preference(:airplane_chat) || Map.get(airplane_endpoint || %{}, :model, "")
        ),
      "offline_chat_disable_reasoning" =>
        model_disables_reasoning?(
          get_model_preference(:airplane_chat) || Map.get(airplane_endpoint || %{}, :model, "")
        ),
      "offline_title_model" => get_model_preference(:airplane_title) || "",
      "offline_image_analysis_model" => get_model_preference(:airplane_image_analysis) || "",
      "offline_chat_images" =>
        model_supports_images?(get_model_preference(:airplane_image_analysis)),
      "system_prompt" => EditorSettings.get_global_setting("ai.system_prompt") || ""
    }
  end

  @spec endpoint_model_options(term(), term()) :: term()
  def endpoint_model_options(assigns, endpoint_key) do
    assigns
    |> Map.get(:settings_editor_endpoint_models, %{})
    |> Map.get(endpoint_key, [])
  end

  @spec update_ai_draft(term(), term(), term()) :: term()
  def update_ai_draft(socket, params, reload) do
    socket
    |> assign(:settings_editor_ai_draft, normalize_ai_params(params))
    |> reload.(socket.assigns.workbench)
  end

  @spec refresh_ai_models(term(), term(), term(), term()) :: term()
  def refresh_ai_models(socket, endpoint_key, reload, append_output) do
    attrs = ai_attrs(socket.assigns)

    with {:ok, endpoint} <- endpoint_refresh_attrs(endpoint_key, attrs),
         {:ok, models} <- AI.list_endpoint_models(endpoint) do
      notify_models_loaded(models)

      socket
      |> assign(
        :settings_editor_endpoint_models,
        Map.put(
          socket.assigns[:settings_editor_endpoint_models] || %{},
          endpoint_key,
          models
        )
      )
      |> reload.(socket.assigns.workbench)
    else
      {:error, reason} ->
        message = ai_error_message(reason)
        Notify.alert(dgettext("ui", "Could not load models"), message)

        socket
        |> append_output.(dgettext("ui", "AI Settings"), message, nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec save_ai(term(), term(), term()) :: term()
  def save_ai(socket, reload, append_output) do
    do_save_ai(socket, reload, append_output)
  rescue
    error ->
      Logger.error("AI settings save crashed: #{Exception.format(:error, error, __STACKTRACE__)}")
      surface_ai_error(socket, reload, append_output, error)
  end

  defp do_save_ai(socket, reload, append_output) do
    attrs = ai_attrs(socket.assigns)

    with :ok <-
           put_endpoint_preferences(
             :online,
             attrs.online_url,
             attrs.online_api_key,
             attrs.online_chat_model
           ),
         :ok <-
           put_endpoint_preferences(
             :airplane,
             attrs.offline_url,
             attrs.offline_api_key,
             attrs.offline_chat_model
           ),
         :ok <- AI.delete_endpoint(:mistral),
         :ok <- AI.set_airplane_mode(attrs.offline_mode),
         :ok <- maybe_put_model_preference(:chat, attrs.online_chat_model),
         :ok <-
           maybe_put_chat_model_capabilities(
             attrs.online_chat_model,
             attrs.online_chat_tools,
             attrs.online_chat_disable_reasoning
           ),
         :ok <- maybe_put_model_preference(:title, attrs.online_title_model),
         :ok <- maybe_put_model_preference(:image_analysis, attrs.online_image_analysis_model),
         :ok <-
           maybe_put_image_model_capabilities(
             attrs.online_image_analysis_model,
             attrs.online_chat_images
           ),
         :ok <- maybe_put_model_preference(:airplane_chat, attrs.offline_chat_model),
         :ok <-
           maybe_put_chat_model_capabilities(
             attrs.offline_chat_model,
             attrs.offline_chat_tools,
             attrs.offline_chat_disable_reasoning
           ),
         :ok <- maybe_put_model_preference(:airplane_title, attrs.offline_title_model),
         :ok <-
           maybe_put_model_preference(
             :airplane_image_analysis,
             attrs.offline_image_analysis_model
           ),
         :ok <-
           maybe_put_image_model_capabilities(
             attrs.offline_image_analysis_model,
             attrs.offline_chat_images
           ),
         :ok <- EditorSettings.put_global_setting("ai.system_prompt", attrs.system_prompt) do
      LiveToast.send_toast(:info, dgettext("ui", "AI settings saved."))

      socket
      |> assign(:settings_editor_ai_draft, %{})
      |> assign(:offline_mode, attrs.offline_mode)
      |> reload.(socket.assigns.workbench)
    else
      {:error, reason} ->
        surface_ai_error(socket, reload, append_output, reason)
    end
  end

  defp notify_models_loaded([]) do
    LiveToast.send_toast(
      :info,
      dgettext(
        "ui",
        "The endpoint returned no models. You can still type a model name manually."
      )
    )
  end

  defp notify_models_loaded(models) do
    LiveToast.send_toast(
      :info,
      dgettext("ui", "Loaded %{count} models.", count: length(models))
    )
  end

  defp surface_ai_error(socket, reload, append_output, reason) do
    message = ai_error_message(reason)
    Notify.alert(dgettext("ui", "Could not save AI settings"), message)

    socket
    |> append_output.(dgettext("ui", "AI Settings"), message, nil, "error")
    |> reload.(socket.assigns.workbench)
  end

  defp ai_error_message(%{__exception__: true} = error), do: Exception.message(error)
  defp ai_error_message(reason) when is_binary(reason), do: reason
  defp ai_error_message(reason), do: inspect(reason)

  @spec reset_ai_prompt(term(), term(), term()) :: term()
  def reset_ai_prompt(socket, reload, append_output) do
    case EditorSettings.put_global_setting("ai.system_prompt", "") do
      :ok ->
        socket
        |> assign(:settings_editor_ai_draft, %{})
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(dgettext("ui", "AI Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  defp safe_endpoint(kind) do
    case AI.get_endpoint(kind) do
      {:ok, ep} -> ep
      error ->
        Logger.debug("swallowed AI settings safe_endpoint error: #{inspect(error)}")
        nil
    end
  end

  defp ai_attrs(assigns) do
    # Merge the stored form with the edit draft so untouched fields (URLs, API
    # keys) are preserved on save instead of being read as nil and wiped.
    draft = Map.merge(ai_form(assigns), Map.get(assigns, :settings_editor_ai_draft, %{}))

    %{
      online_url: blank_to_nil(Map.get(draft, "online_url")),
      online_api_key: blank_to_nil(Map.get(draft, "online_api_key")),
      online_chat_model: blank_to_nil(Map.get(draft, "online_chat_model")),
      online_chat_tools: truthy?(Map.get(draft, "online_chat_tools")),
      online_chat_disable_reasoning: truthy?(Map.get(draft, "online_chat_disable_reasoning")),
      online_title_model: blank_to_nil(Map.get(draft, "online_title_model")),
      online_image_analysis_model: blank_to_nil(Map.get(draft, "online_image_analysis_model")),
      online_chat_images: truthy?(Map.get(draft, "online_chat_images")),
      offline_url: blank_to_nil(Map.get(draft, "offline_url")),
      offline_api_key: blank_to_nil(Map.get(draft, "offline_api_key")),
      offline_mode: truthy?(Map.get(draft, "offline_mode")),
      offline_chat_model: blank_to_nil(Map.get(draft, "offline_chat_model")),
      offline_chat_tools: truthy?(Map.get(draft, "offline_chat_tools")),
      offline_chat_disable_reasoning: truthy?(Map.get(draft, "offline_chat_disable_reasoning")),
      offline_title_model: blank_to_nil(Map.get(draft, "offline_title_model")),
      offline_image_analysis_model: blank_to_nil(Map.get(draft, "offline_image_analysis_model")),
      offline_chat_images: truthy?(Map.get(draft, "offline_chat_images")),
      system_prompt: Map.get(draft, "system_prompt", "")
    }
  end

  defp normalize_ai_params(params) do
    %{
      "online_url" => Map.get(params, "online_url", ""),
      "online_api_key" => Map.get(params, "online_api_key", ""),
      "online_chat_model" => Map.get(params, "online_chat_model", ""),
      "online_chat_tools" => truthy?(Map.get(params, "online_chat_tools")),
      "online_chat_disable_reasoning" =>
        truthy?(Map.get(params, "online_chat_disable_reasoning")),
      "online_title_model" => Map.get(params, "online_title_model", ""),
      "online_image_analysis_model" => Map.get(params, "online_image_analysis_model", ""),
      "online_chat_images" => truthy?(Map.get(params, "online_chat_images")),
      "offline_url" => Map.get(params, "offline_url", ""),
      "offline_api_key" => Map.get(params, "offline_api_key", ""),
      "offline_mode" => truthy?(Map.get(params, "offline_mode")),
      "offline_chat_model" => Map.get(params, "offline_chat_model", ""),
      "offline_chat_tools" => truthy?(Map.get(params, "offline_chat_tools")),
      "offline_chat_disable_reasoning" =>
        truthy?(Map.get(params, "offline_chat_disable_reasoning")),
      "offline_title_model" => Map.get(params, "offline_title_model", ""),
      "offline_image_analysis_model" => Map.get(params, "offline_image_analysis_model", ""),
      "offline_chat_images" => truthy?(Map.get(params, "offline_chat_images")),
      "system_prompt" => Map.get(params, "system_prompt", "")
    }
  end

  # Returns nil when no preference is stored so `||` fallbacks to the
  # endpoint's model actually fire.
  defp get_model_preference(key) do
    case AI.get_model_preference(key) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp maybe_put_model_preference(_key, nil), do: :ok
  defp maybe_put_model_preference(_key, ""), do: :ok
  defp maybe_put_model_preference(key, value), do: AI.put_model_preference(key, value)

  defp maybe_put_chat_model_capabilities(nil, _supports_tool_calls, _disables_reasoning), do: :ok
  defp maybe_put_chat_model_capabilities("", _supports_tool_calls, _disables_reasoning), do: :ok

  defp maybe_put_chat_model_capabilities(model, supports_tool_calls, disables_reasoning) do
    existing = BDS.AI.Catalog.model_capabilities(model)

    AI.put_model_capabilities(model, %{
      supports_attachment: existing.supports_attachment,
      supports_tool_calls: supports_tool_calls,
      disables_reasoning: disables_reasoning
    })
  end

  defp maybe_put_image_model_capabilities(nil, _supports_images), do: :ok
  defp maybe_put_image_model_capabilities("", _supports_images), do: :ok

  defp maybe_put_image_model_capabilities(model, supports_images) do
    existing = BDS.AI.Catalog.model_capabilities(model)

    AI.put_model_capabilities(model, %{
      supports_attachment: supports_images,
      supports_tool_calls: existing.supports_tool_calls,
      disables_reasoning: existing.disables_reasoning
    })
  end

  defp model_supports_tool_calls?(nil), do: false
  defp model_supports_tool_calls?(""), do: false

  defp model_supports_tool_calls?(model),
    do: BDS.AI.Catalog.model_capabilities(model).supports_tool_calls

  defp model_supports_images?(nil), do: false
  defp model_supports_images?(""), do: false

  defp model_supports_images?(model),
    do: BDS.AI.Catalog.model_capabilities(model).supports_attachment

  defp model_disables_reasoning?(nil), do: false
  defp model_disables_reasoning?(""), do: false

  defp model_disables_reasoning?(model),
    do: BDS.AI.Catalog.model_capabilities(model).disables_reasoning

  defp put_endpoint_preferences(kind, url, api_key, primary_model) do
    if Enum.all?([url, api_key, primary_model], &(blank_to_nil(&1) == nil)) do
      AI.delete_endpoint(kind)
    else
      AI.put_endpoint(kind, %{url: url, api_key: api_key, model: primary_model})
      |> normalize_endpoint_result()
    end
  end

  defp endpoint_refresh_attrs(:online, attrs) do
    endpoint_refresh_attrs(attrs.online_url, attrs.online_api_key)
  end

  defp endpoint_refresh_attrs(:airplane, attrs) do
    endpoint_refresh_attrs(attrs.offline_url, attrs.offline_api_key)
  end

  defp endpoint_refresh_attrs(url, api_key) do
    case blank_to_nil(url) do
      nil -> {:error, :endpoint_not_configured}
      loaded_url -> {:ok, %{url: loaded_url, api_key: api_key}}
    end
  end

  defp normalize_endpoint_result({:ok, _endpoint}), do: :ok
  defp normalize_endpoint_result({:error, reason}), do: {:error, reason}

  defp truthy?(value), do: BDS.Values.truthy?(value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
