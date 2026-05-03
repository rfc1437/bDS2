defmodule BDS.Desktop.ShellLive.ChatEditor.ModelSelection do
  @moduledoc false

  alias BDS.AI

  import Phoenix.Component, only: [assign: 3]
  use Gettext, backend: BDS.Gettext

  @spec toggle_model_selector(term(), term()) :: term()
  def toggle_model_selector(socket, reload) do
    %{id: conversation_id} = socket.assigns.current_tab
    current = Map.get(socket.assigns.chat_model_selectors_open, conversation_id, false)

    socket
    |> assign(
      :chat_model_selectors_open,
      Map.put(socket.assigns.chat_model_selectors_open, conversation_id, not current)
    )
    |> reload.(socket.assigns.workbench)
  end

  @spec set_model(term(), term(), term(), term()) :: term()
  def set_model(socket, model_id, reload, append_output) do
    %{id: conversation_id} = socket.assigns.current_tab

    case AI.set_conversation_model(conversation_id, model_id) do
      {:ok, _conversation} ->
        socket
        |> assign(
          :chat_model_selectors_open,
          Map.put(socket.assigns.chat_model_selectors_open, conversation_id, false)
        )
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(dgettext("ui", "Chat"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec group_available_models(term()) :: term()
  def group_available_models(models) when is_list(models) do
    models
    |> Enum.group_by(&Map.get(&1, :provider, "other"))
    |> Enum.map(fn {provider, entries} ->
      %{
        provider: provider,
        label: provider_group_label(entries, provider),
        models:
          Enum.sort_by(
            entries,
            &String.downcase(to_string(Map.get(&1, :name) || Map.get(&1, :id)))
          )
      }
    end)
    |> Enum.sort_by(&String.downcase(to_string(&1.label)))
  end

  @spec needs_api_key?(term()) :: term()
  def needs_api_key?(true), do: false

  def needs_api_key?(false) do
    case AI.get_endpoint(:online) do
      {:ok, %{url: url, model: model, api_key: api_key}} ->
        blank?(url) or blank?(model) or blank?(api_key)

      _other ->
        true
    end
  end

  defp provider_group_label([%{provider_name: name} | _entries], _provider)
       when is_binary(name) and name != "",
       do: name

  defp provider_group_label(_entries, provider) when is_binary(provider), do: provider

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
end
