defmodule BDS.Desktop.ShellLive.CliSync do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.{Media, Posts}
  alias BDS.MapUtils
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Posts.Post
  alias BDS.UI.Workbench

  @doc """
  Apply a CLI entity change payload to the shell socket. `reload_fun` is
  called with `(socket, workbench)` to refresh derived data.
  """
  @spec apply_entity_change(Phoenix.LiveView.Socket.t(), map(), (Phoenix.LiveView.Socket.t(),
                                                                 map() ->
                                                                   Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def apply_entity_change(socket, payload, reload_fun) do
    entity = MapUtils.attr(payload, :entity) || MapUtils.attr(payload, :entity_type)

    entity_id =
      MapUtils.attr(payload, :entity_id) || Map.get(payload, :entityId) ||
        Map.get(payload, "entityId")

    action = normalize_action(MapUtils.attr(payload, :action))

    if is_binary(entity) and entity != "" and is_binary(entity_id) and entity_id != "" and
         action in [:created, :updated, :deleted] do
      {socket, workbench} = maybe_close_deleted_tab(socket, entity, entity_id, action)

      socket
      |> maybe_refresh_tab_meta(entity, entity_id, action)
      |> reload_fun.(workbench)
    else
      socket
    end
  end

  defp maybe_close_deleted_tab(socket, "post", post_id, :deleted) do
    workbench = Workbench.close_tab(socket.assigns.workbench, :post, post_id)

    socket =
      socket
      |> assign(:workbench, workbench)
      |> assign(:shell_overlay, nil)
      |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {:post, post_id}))

    {socket, workbench}
  end

  defp maybe_close_deleted_tab(socket, "media", media_id, :deleted) do
    workbench = Workbench.close_tab(socket.assigns.workbench, :media, media_id)

    socket =
      socket
      |> assign(:workbench, workbench)
      |> assign(:shell_overlay, nil)
      |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {:media, media_id}))
      |> assign(:media_editor_drafts, Map.delete(socket.assigns.media_editor_drafts, media_id))
      |> assign(
        :media_editor_quick_actions_open,
        Map.delete(socket.assigns.media_editor_quick_actions_open, media_id)
      )
      |> assign(
        :media_editor_post_pickers_open,
        Map.delete(socket.assigns.media_editor_post_pickers_open, media_id)
      )
      |> assign(
        :media_editor_post_picker_queries,
        Map.delete(socket.assigns.media_editor_post_picker_queries, media_id)
      )
      |> assign(
        :media_editor_save_states,
        Map.delete(socket.assigns.media_editor_save_states, media_id)
      )
      |> assign(
        :media_editor_translation_forms,
        Map.delete(socket.assigns.media_editor_translation_forms, media_id)
      )

    {socket, workbench}
  end

  defp maybe_close_deleted_tab(socket, _entity, _entity_id, _action),
    do: {socket, socket.assigns.workbench}

  defp maybe_refresh_tab_meta(socket, "post", post_id, action)
       when action in [:created, :updated] do
    maybe_put_tab_meta(socket, :post, post_id, fn ->
      case Posts.get_post(post_id) do
        %Post{} = post ->
          %{title: post.title || post.slug || post.id, subtitle: Atom.to_string(post.status)}

        _other ->
          nil
      end
    end)
  end

  defp maybe_refresh_tab_meta(socket, "media", media_id, action)
       when action in [:created, :updated] do
    maybe_put_tab_meta(socket, :media, media_id, fn ->
      case Media.get_media(media_id) do
        %MediaRecord{} = media ->
          %{
            title: media.title || media.filename || media.id,
            subtitle: media.filename || media.mime_type || "media"
          }

        _other ->
          nil
      end
    end)
  end

  defp maybe_refresh_tab_meta(socket, _entity, _entity_id, _action), do: socket

  defp maybe_put_tab_meta(socket, route, entity_id, meta_fun) do
    key = {route, entity_id}

    if tab_present?(socket.assigns.workbench, key) or Map.has_key?(socket.assigns.tab_meta, key) do
      case meta_fun.() do
        %{} = fresh_meta ->
          updated_meta =
            Map.update(socket.assigns.tab_meta, key, fresh_meta, &Map.merge(&1, fresh_meta))

          assign(socket, :tab_meta, updated_meta)

        _other ->
          socket
      end
    else
      socket
    end
  end

  defp tab_present?(%{tabs: tabs}, {route, entity_id}) do
    Enum.any?(tabs, &(&1.type == route and &1.id == entity_id))
  end

  defp normalize_action(action) when action in [:created, :updated, :deleted], do: action

  defp normalize_action(action) do
    action
    |> to_string()
    |> String.downcase()
    |> case do
      "created" -> :created
      "updated" -> :updated
      "deleted" -> :deleted
      _other -> :unknown
    end
  end
end
