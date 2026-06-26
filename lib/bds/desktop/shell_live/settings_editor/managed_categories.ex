defmodule BDS.Desktop.ShellLive.SettingsEditor.ManagedCategories do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Metadata
  use Gettext, backend: BDS.Gettext

  @protected_categories MapSet.new(["article", "aside", "page", "picture"])
  @default_category_settings %{
    "article" => %{title: "article", render_in_lists: true, show_title: true},
    "picture" => %{title: "picture", render_in_lists: true, show_title: true},
    "aside" => %{title: "aside", render_in_lists: true, show_title: false},
    "page" => %{title: "page", render_in_lists: false, show_title: true}
  }

  @spec protected_categories() :: term()
  def protected_categories, do: @protected_categories

  @spec protected_category?(term()) :: term()
  def protected_category?(category), do: MapSet.member?(@protected_categories, category)

  @spec category_rows(term()) :: term()
  def category_rows(metadata) do
    categories = metadata.categories
    settings = metadata.category_settings

    Enum.map(categories, fn category ->
      category_settings = Map.get(settings, category, %{})

      %{
        name: category,
        title: Map.get(category_settings, "title") || category,
        render_in_lists: Map.get(category_settings, "render_in_lists", true),
        show_title: Map.get(category_settings, "show_title", true),
        post_template_slug: Map.get(category_settings, "post_template_slug", ""),
        list_template_slug: Map.get(category_settings, "list_template_slug", ""),
        protected?: protected_category?(category)
      }
    end)
  end

  @spec update_new_category(term(), term(), term()) :: term()
  def update_new_category(socket, name, reload) do
    socket
    |> assign(:settings_editor_new_category, to_string(name || ""))
    |> reload.(socket.assigns.workbench)
  end

  @spec add_category(term(), term(), term()) :: term()
  def add_category(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id
    name = socket.assigns[:settings_editor_new_category] |> to_string() |> String.trim()

    cond do
      name == "" ->
        socket
        |> append_output.(
          dgettext("ui", "Categories"),
          dgettext("ui", "Category name is required"),
          nil,
          "error"
        )
        |> reload.(socket.assigns.workbench)

      true ->
        case Metadata.add_category(project_id, name) do
          {:ok, _metadata} ->
            socket
            |> assign(:settings_editor_new_category, "")
            |> reload.(socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output.(dgettext("ui", "Categories"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  @spec reset_categories(term(), term(), term()) :: term()
  def reset_categories(socket, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id

    result =
      Enum.reduce_while(category_names(project_metadata(socket.assigns)), :ok, fn category,
                                                                                  _acc ->
        if MapSet.member?(@protected_categories, category) do
          {:cont, :ok}
        else
          case Metadata.remove_category(project_id, category) do
            {:ok, _metadata} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      end)

    with :ok <- result,
         :ok <- ensure_default_categories(project_id),
         :ok <- reset_default_category_settings(project_id) do
      socket
      |> assign(:settings_editor_new_category, "")
      |> reload.(socket.assigns.workbench)
    else
      {:error, reason} ->
        socket
        |> append_output.(dgettext("ui", "Categories"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec save_category(term(), term(), term(), term()) :: term()
  def save_category(socket, params, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id
    category = Map.get(params, "category", "")

    settings = %{
      title: blank_to_nil(Map.get(params, "title")),
      render_in_lists: truthy?(Map.get(params, "render_in_lists")),
      show_title: truthy?(Map.get(params, "show_title")),
      post_template_slug: blank_to_nil(Map.get(params, "post_template_slug")),
      list_template_slug: blank_to_nil(Map.get(params, "list_template_slug"))
    }

    case Metadata.update_category_settings(project_id, category, settings) do
      {:ok, _metadata} ->
        reload.(socket, socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(dgettext("ui", "Categories"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec remove_category(term(), term(), term(), term()) :: term()
  def remove_category(socket, category, reload, append_output) do
    project_id = socket.assigns.projects.active_project_id

    cond do
      MapSet.member?(@protected_categories, category) ->
        socket
        |> append_output.(
          dgettext("ui", "Categories"),
          dgettext("ui", "Protected categories cannot be removed"),
          nil,
          "error"
        )
        |> reload.(socket.assigns.workbench)

      true ->
        case Metadata.remove_category(project_id, category) do
          {:ok, _metadata} ->
            reload.(socket, socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output.(dgettext("ui", "Categories"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  defp project_metadata(assigns) do
    case Metadata.get_project_metadata(assigns.projects.active_project_id) do
      {:ok, metadata} -> metadata
    end
  end

  defp category_names(metadata), do: metadata.categories

  defp ensure_default_categories(project_id) do
    Enum.reduce_while(Map.keys(@default_category_settings), :ok, fn category, _acc ->
      case Metadata.add_category(project_id, category) do
        {:ok, _metadata} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reset_default_category_settings(project_id) do
    Enum.reduce_while(@default_category_settings, :ok, fn {category, settings}, _acc ->
      case Metadata.update_category_settings(project_id, category, settings) do
        {:ok, _metadata} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp truthy?(value), do: BDS.Values.truthy?(value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
