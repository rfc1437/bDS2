defmodule BDS.Desktop.ShellLive.SettingsEditor.AISettings do
  @moduledoc false

  use Phoenix.Component

  alias BDS.AI
  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.SettingsEditor.EditorSettings

  def ai_form(assigns) do
    {:ok, online_endpoint} = AI.get_endpoint(:online)
    {:ok, airplane_endpoint} = AI.get_endpoint(:airplane)

    %{
      "online_url" => Map.get(online_endpoint || %{}, :url, ""),
      "online_api_key" => Map.get(online_endpoint || %{}, :api_key, ""),
      "online_chat_model" =>
        get_model_preference(:chat) || Map.get(online_endpoint || %{}, :model, ""),
      "online_title_model" => get_model_preference(:title),
      "online_image_analysis_model" => get_model_preference(:image_analysis),
      "offline_url" => Map.get(airplane_endpoint || %{}, :url, ""),
      "offline_api_key" => Map.get(airplane_endpoint || %{}, :api_key, ""),
      "offline_mode" => Map.get(assigns, :offline_mode, AI.airplane_mode?(true)),
      "offline_chat_model" =>
        get_model_preference(:airplane_chat) ||
          Map.get(airplane_endpoint || %{}, :model, ""),
      "offline_title_model" => get_model_preference(:airplane_title),
      "offline_image_analysis_model" => get_model_preference(:airplane_image_analysis),
      "system_prompt" => EditorSettings.get_global_setting("ai.system_prompt") || ""
    }
  end

  def endpoint_model_options(assigns, endpoint_key) do
    assigns
    |> Map.get(:settings_editor_endpoint_models, %{})
    |> Map.get(endpoint_key, [])
  end

  def update_ai_draft(socket, params, reload) do
    socket
    |> assign(:settings_editor_ai_draft, normalize_ai_params(params))
    |> reload.(socket.assigns.workbench)
  end

  def refresh_ai_models(socket, endpoint_key, reload, append_output) do
    attrs = ai_attrs(socket.assigns)

    with {:ok, endpoint} <- endpoint_refresh_attrs(endpoint_key, attrs),
         {:ok, models} <- AI.list_endpoint_models(endpoint) do
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
        socket
        |> append_output.(translated("AI Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def save_ai(socket, reload, append_output) do
    attrs = ai_attrs(socket.assigns)

    with :ok <-
           put_endpoint_preferences(:online, attrs.online_url, attrs.online_api_key, attrs.online_chat_model),
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
         :ok <- maybe_put_model_preference(:title, attrs.online_title_model),
         :ok <- maybe_put_model_preference(:image_analysis, attrs.online_image_analysis_model),
         :ok <- maybe_put_model_preference(:airplane_chat, attrs.offline_chat_model),
         :ok <- maybe_put_model_preference(:airplane_title, attrs.offline_title_model),
         :ok <-
           maybe_put_model_preference(:airplane_image_analysis, attrs.offline_image_analysis_model),
         :ok <- EditorSettings.put_global_setting("ai.system_prompt", attrs.system_prompt) do
      socket
      |> assign(:settings_editor_ai_draft, %{})
      |> assign(:offline_mode, attrs.offline_mode)
      |> reload.(socket.assigns.workbench)
    else
      {:error, reason} ->
        socket
        |> append_output.(translated("AI Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def reset_ai_prompt(socket, reload, append_output) do
    case EditorSettings.put_global_setting("ai.system_prompt", "") do
      :ok ->
        socket
        |> assign(:settings_editor_ai_draft, %{})
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("AI Settings"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  defp ai_attrs(assigns) do
    draft = Map.get(assigns, :settings_editor_ai_draft, %{})

    %{
      online_url: blank_to_nil(Map.get(draft, "online_url")),
      online_api_key: blank_to_nil(Map.get(draft, "online_api_key")),
      online_chat_model: blank_to_nil(Map.get(draft, "online_chat_model")),
      online_title_model: blank_to_nil(Map.get(draft, "online_title_model")),
      online_image_analysis_model: blank_to_nil(Map.get(draft, "online_image_analysis_model")),
      offline_url: blank_to_nil(Map.get(draft, "offline_url")),
      offline_api_key: blank_to_nil(Map.get(draft, "offline_api_key")),
      offline_mode: truthy?(Map.get(draft, "offline_mode")),
      offline_chat_model: blank_to_nil(Map.get(draft, "offline_chat_model")),
      offline_title_model: blank_to_nil(Map.get(draft, "offline_title_model")),
      offline_image_analysis_model: blank_to_nil(Map.get(draft, "offline_image_analysis_model")),
      system_prompt: Map.get(draft, "system_prompt", "")
    }
  end

  defp normalize_ai_params(params) do
    %{
      "online_url" => Map.get(params, "online_url", ""),
      "online_api_key" => Map.get(params, "online_api_key", ""),
      "online_chat_model" => Map.get(params, "online_chat_model", ""),
      "online_title_model" => Map.get(params, "online_title_model", ""),
      "online_image_analysis_model" => Map.get(params, "online_image_analysis_model", ""),
      "offline_url" => Map.get(params, "offline_url", ""),
      "offline_api_key" => Map.get(params, "offline_api_key", ""),
      "offline_mode" => truthy?(Map.get(params, "offline_mode")),
      "offline_chat_model" => Map.get(params, "offline_chat_model", ""),
      "offline_title_model" => Map.get(params, "offline_title_model", ""),
      "offline_image_analysis_model" => Map.get(params, "offline_image_analysis_model", ""),
      "system_prompt" => Map.get(params, "system_prompt", "")
    }
  end

  defp get_model_preference(key) do
    case AI.get_model_preference(key) do
      {:ok, value} -> value || ""
      _other -> ""
    end
  end

  defp maybe_put_model_preference(_key, nil), do: :ok
  defp maybe_put_model_preference(_key, ""), do: :ok
  defp maybe_put_model_preference(key, value), do: AI.put_model_preference(key, value)

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

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
