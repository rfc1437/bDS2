defmodule BDS.Desktop.ShellLive.OverlayManager do
  @moduledoc false

  require Logger

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [send_update: 2]

  alias BDS.{AI, Media, Metadata, Tags}
  alias BDS.Desktop.{Overlay}

  alias BDS.Desktop.ShellLive.{
    MediaEditor,
    Notify,
    PostEditor,
    TabHelpers
  }

  alias BDS.Desktop.ShellLive.OverlayComponents, as: ShellOverlayComponents
  use Gettext, backend: BDS.Gettext

  # ── Event handlers ─────────────────────────────────────────────────────────

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("open_overlay", %{"kind" => kind}, socket, callbacks) do
    socket =
      case socket.assigns[:current_tab] do
        %{type: :post, id: post_id}
        when kind in ["ai_suggestions", "language_picker"] ->
          send_update(PostEditor,
            id: "post-editor-#{post_id}",
            action: :close_quick_actions
          )

          socket

        %{type: :media, id: media_id}
        when kind in ["ai_suggestions", "language_picker", "confirm_delete"] ->
          send_update(MediaEditor,
            id: "media-editor-#{media_id}",
            action: :close_quick_actions
          )

          socket

        _other ->
          socket
      end

    overlay =
      with overlay_kind when not is_nil(overlay_kind) <- ShellOverlayComponents.kind(kind),
           %{type: route} <- socket.assigns[:current_tab] do
        tab = socket.assigns.current_tab
        title = TabHelpers.tab_title(tab, socket.assigns.tab_meta)
        subtitle = TabHelpers.tab_subtitle(tab, socket.assigns.tab_meta)

        Overlay.open(
          route,
          overlay_kind,
          ShellOverlayComponents.context(socket.assigns, title, subtitle)
        )
      end

    socket = assign(socket, :shell_overlay, overlay)

    socket =
      if kind == "ai_suggestions" and not is_nil(overlay) do
        if socket.assigns.offline_mode do
          callbacks.append_output.(
            socket,
            dgettext("ui", "AI Suggestions"),
            dgettext("ui", "Automatic AI actions stay gated by airplane mode."),
            nil,
            "info"
          )
          |> assign(:shell_overlay, nil)
        else
          spawn_ai_suggestions_task(socket)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("close_overlay", _params, socket, _callbacks) do
    {:noreply, assign(socket, :shell_overlay, nil)}
  end

  def handle_event("overlay_keydown", %{"key" => key}, socket, _callbacks) do
    socket =
      case {socket.assigns[:shell_overlay], key} do
        {nil, _other} ->
          socket

        {_overlay, "Escape"} ->
          assign(socket, :shell_overlay, nil)

        {%{kind: :gallery} = overlay, "ArrowLeft"} ->
          assign(socket, :shell_overlay, Overlay.lightbox_previous(overlay))

        {%{kind: :gallery} = overlay, "ArrowRight"} ->
          assign(socket, :shell_overlay, Overlay.lightbox_next(overlay))

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_toggle_ai_field", %{"key" => key}, socket, _callbacks) do
    {:noreply, update_shell_overlay(socket, &Overlay.toggle_ai_field(&1, key))}
  end

  def handle_event("overlay_set_search", %{"overlay" => %{"query" => query}}, socket, _callbacks) do
    {:noreply, update_shell_overlay(socket, &Overlay.set_search_query(&1, query))}
  end

  def handle_event("overlay_set_tab", %{"tab" => tab}, socket, _callbacks) do
    {:noreply,
     update_shell_overlay(socket, &Overlay.set_active_tab(&1, ShellOverlayComponents.tab(tab)))}
  end

  def handle_event("overlay_update_form", %{"overlay" => params}, socket, _callbacks) do
    socket =
      socket
      |> update_shell_overlay(
        &Overlay.update_form_value(&1, :external_url, Map.get(params, "url", ""))
      )
      |> update_shell_overlay(
        &Overlay.update_form_value(&1, :external_text, Map.get(params, "text", ""))
      )

    {:noreply, socket}
  end

  def handle_event("overlay_select_result", %{"id" => id}, socket, _callbacks) do
    overlay = socket.assigns[:shell_overlay]
    current_tab = socket.assigns[:current_tab]

    socket =
      case {overlay, current_tab} do
        {%{kind: :insert_link}, %{type: :post, id: post_id}} ->
          case Overlay.insert_link_result(overlay, id) do
            nil ->
              socket

            result ->
              send(
                self(),
                {:post_editor_insert_content, post_id,
                 ShellOverlayComponents.markdown_link(result.title, result.canonical_url)}
              )

              socket
          end

        {%{kind: :insert_media}, %{type: :post, id: post_id}} ->
          case Overlay.insert_media_result(overlay, id) do
            nil ->
              socket

            result ->
              syntax =
                if result.is_image do
                  "![#{result.title}](bds-media://#{result.media_id})"
                else
                  "[#{result.original_name}](bds-media://#{result.media_id})"
                end

              Notify.parent({:post_editor_insert_content, post_id, syntax})
              socket
          end

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_insert_external", _params, socket, _callbacks) do
    current_tab = socket.assigns[:current_tab]

    socket =
      case {socket.assigns[:shell_overlay], current_tab} do
        {%{kind: :insert_link} = overlay, %{type: :post, id: post_id}} ->
          details =
            case {overlay.external_url, String.trim(overlay.external_text || "")} do
              {"", _text} -> nil
              {url, ""} -> url
              {url, text} -> ShellOverlayComponents.markdown_link(text, url)
            end

          if details do
            Notify.parent({:post_editor_insert_content, post_id, details})
          end

          socket

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_select_language", %{"code" => code}, socket, _callbacks) do
    current_tab = socket.assigns[:current_tab]

    socket =
      case {socket.assigns[:shell_overlay], current_tab} do
        {%{kind: :language_picker}, %{type: :post, id: post_id}} ->
          Notify.parent({:post_editor_translate, post_id, code})
          socket

        {%{kind: :language_picker}, %{type: :media, id: media_id}} ->
          send_update(MediaEditor,
            id: "media-editor-#{media_id}",
            action: :translate,
            language: code
          )

          socket

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_confirm", _params, socket, callbacks) do
    current_tab = socket.assigns[:current_tab]

    socket =
      case {socket.assigns[:shell_overlay], current_tab} do
        {%{kind: :confirm_delete, delete_action: %{source: :sidebar, route: route, id: id}}, _tab} ->
          callbacks.execute_sidebar_delete.(socket, route, id)

        {%{kind: :ai_suggestions} = overlay, %{type: :post, id: post_id}} ->
          send(
            self(),
            {:post_editor_apply_ai_suggestions, post_id, Overlay.selected_ai_fields(overlay)}
          )

          socket

        {%{kind: :ai_suggestions} = overlay, %{type: :media, id: media_id}} ->
          send_update(MediaEditor,
            id: "media-editor-#{media_id}",
            action: :apply_ai_suggestions,
            fields: Overlay.selected_ai_fields(overlay)
          )

          socket

        {%{kind: :confirm_delete}, %{type: :media, id: media_id}} ->
          case Media.delete_media(media_id) do
            {:ok, :deleted} ->
              workbench = BDS.UI.Workbench.close_tab(socket.assigns.workbench, :media, media_id)

              socket
              |> assign(:shell_overlay, nil)
              |> assign(
                :tab_meta,
                Map.delete(socket.assigns.tab_meta, {:media, media_id})
              )
              |> callbacks.reload.(workbench)

            {:error, reason} ->
              socket
              |> assign(:shell_overlay, nil)
              |> callbacks.append_output.(
                dgettext("ui", "Delete Media"),
                inspect(reason),
                nil,
                "error"
              )
              |> callbacks.reload.(socket.assigns.workbench)
          end

        {%{kind: :confirm_delete, title: title, entity_name: entity_name}, _tab} ->
          close_overlay_with_output(socket, callbacks.append_output, title, entity_name)

        {%{kind: :confirm_dialog, confirm_action: :delete_tag, tag_id: tag_id}, _tab} ->
          case Tags.delete_tag(tag_id) do
            {:ok, :deleted} ->
              socket
              |> assign(:shell_overlay, nil)
              |> callbacks.reload.(socket.assigns.workbench)

            {:error, reason} ->
              socket
              |> assign(:shell_overlay, nil)
              |> callbacks.append_output.(
                dgettext("ui", "Delete Tag"),
                inspect(reason),
                nil,
                "error"
              )
              |> callbacks.reload.(socket.assigns.workbench)
          end

        {%{kind: :confirm_dialog, title: title, message: message}, _tab} ->
          close_overlay_with_output(socket, callbacks.append_output, title, message)

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("overlay_select_gallery_image", %{"id" => id}, socket, _callbacks) do
    {:noreply, update_shell_overlay(socket, &Overlay.select_gallery_image(&1, id))}
  end

  def handle_event("overlay_close_lightbox", _params, socket, _callbacks) do
    {:noreply, update_shell_overlay(socket, &Overlay.close_lightbox/1)}
  end

  def handle_event("overlay_lightbox_previous", _params, socket, _callbacks) do
    {:noreply, update_shell_overlay(socket, &Overlay.lightbox_previous/1)}
  end

  def handle_event("overlay_lightbox_next", _params, socket, _callbacks) do
    {:noreply, update_shell_overlay(socket, &Overlay.lightbox_next/1)}
  end

  # ── handle_info for async AI suggestions ───────────────────────────────────

  @spec handle_info(tuple(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:ai_suggestions_result, type, id, result}, socket) do
    socket =
      case socket.assigns[:shell_overlay] do
        %{kind: :ai_suggestions} = overlay ->
          current_tab = socket.assigns.current_tab

          if current_tab && current_tab.type == type && current_tab.id == id do
            suggestions =
              case type do
                :post ->
                  %{
                    "title" => result.title,
                    "excerpt" => result.excerpt,
                    "slug" => result.slug
                  }

                :media ->
                  %{
                    "title" => result.title,
                    "alt" => result.alt,
                    "caption" => result.caption
                  }
              end

            assign(socket, :shell_overlay, Overlay.set_ai_suggestions(overlay, suggestions))
          else
            socket
          end

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:ai_suggestions_error, type, id, reason}, socket) do
    Logger.error("AI suggestions error type=#{type} id=#{id} reason=#{inspect(reason)}")

    socket =
      case socket.assigns[:shell_overlay] do
        %{kind: :ai_suggestions} = overlay ->
          current_tab = socket.assigns.current_tab

          if current_tab && current_tab.type == type && current_tab.id == id do
            message =
              if is_map(reason) and Map.has_key?(reason, :kind) do
                "#{reason.kind}: #{inspect(Map.drop(reason, [:kind]))}"
              else
                inspect(reason)
              end

            assign(socket, :shell_overlay, Overlay.set_ai_suggestions_error(overlay, message))
          else
            socket
          end

        _other ->
          socket
      end

    {:noreply, socket}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec update_shell_overlay(Phoenix.LiveView.Socket.t(), (map() -> map())) ::
          Phoenix.LiveView.Socket.t()
  defp update_shell_overlay(socket, updater) do
    case socket.assigns[:shell_overlay] do
      nil -> socket
      overlay -> assign(socket, :shell_overlay, updater.(overlay))
    end
  end

  @spec close_overlay_with_output(
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t(), String.t(), String.t(), any(), String.t() ->
             Phoenix.LiveView.Socket.t()),
          String.t(),
          any()
        ) :: Phoenix.LiveView.Socket.t()
  defp close_overlay_with_output(socket, append_output, title, details) do
    socket
    |> append_output.(title, dgettext("ui", "Command completed"), details, "info")
    |> assign(:shell_overlay, nil)
  end

  @spec spawn_ai_suggestions_task(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp spawn_ai_suggestions_task(socket) do
    current_tab = socket.assigns.current_tab
    language = ai_suggestions_language(socket)

    case current_tab do
      %{type: :post, id: post_id} ->
        parent = self()

        Task.Supervisor.start_child(BDS.TCP.TaskSupervisor, fn ->
          case AI.analyze_post(post_id, language: language) do
            {:ok, result} ->
              send(parent, {:ai_suggestions_result, :post, post_id, result})

            {:error, reason} ->
              send(parent, {:ai_suggestions_error, :post, post_id, reason})
          end
        end)

      %{type: :media, id: media_id} ->
        parent = self()

        Task.Supervisor.start_child(BDS.TCP.TaskSupervisor, fn ->
          case AI.analyze_image(media_id, language: language) do
            {:ok, result} ->
              send(parent, {:ai_suggestions_result, :media, media_id, result})

            {:error, reason} ->
              send(parent, {:ai_suggestions_error, :media, media_id, reason})
          end
        end)

      _other ->
        :ok
    end

    socket
  end

  @spec ai_suggestions_language(Phoenix.LiveView.Socket.t()) :: String.t()
  defp ai_suggestions_language(socket) do
    active_project_id = socket.assigns.projects.active_project_id
    {:ok, metadata} = Metadata.get_project_metadata(active_project_id)
    metadata.main_language || "en"
  rescue
    _error -> "en"
  end
end
