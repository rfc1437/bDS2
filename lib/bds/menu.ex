defmodule BDS.Menu do
  @moduledoc false

  alias BDS.Persistence
  alias BDS.Projects

  defmodule OpmlHandler do
    @moduledoc false

    @behaviour Saxy.Handler

    # Collects /opml/body/outline trees as {attrs_map, children} tuples without
    # interning element or attribute names as atoms. Outlines outside the body
    # (or separated from their outline parent by a foreign element) are pushed
    # as :ignored frames so the stack stays balanced.
    def handle_event(:start_document, _prolog, state), do: {:ok, state}
    def handle_event(:end_document, _data, state), do: {:ok, state}
    def handle_event(:characters, _chars, state), do: {:ok, state}
    def handle_event(:cdata, _chars, state), do: {:ok, state}

    def handle_event(:start_element, {name, attributes}, state) do
      state =
        if name == "outline" do
          frame =
            if collect_outline?(state) do
              {Map.new(attributes), []}
            else
              :ignored
            end

          %{state | stack: [frame | state.stack]}
        else
          state
        end

      {:ok, %{state | path: [name | state.path]}}
    end

    def handle_event(:end_element, name, state) do
      state = %{state | path: tl(state.path)}
      state = if name == "outline", do: pop_outline(state), else: state
      {:ok, state}
    end

    defp collect_outline?(%{path: ["body", "opml"]}), do: true

    defp collect_outline?(%{path: ["outline" | _rest], stack: [{_attrs, _children} | _frames]}),
      do: true

    defp collect_outline?(_state), do: false

    defp pop_outline(%{stack: [:ignored | rest]} = state), do: %{state | stack: rest}

    defp pop_outline(%{stack: [{attrs, children} | rest]} = state) do
      outline = {attrs, Enum.reverse(children)}

      case rest do
        [{parent_attrs, parent_children} | frames] ->
          %{state | stack: [{parent_attrs, [outline | parent_children]} | frames]}

        _top_level ->
          %{state | stack: rest, outlines: [outline | state.outlines]}
      end
    end

    defp pop_outline(state), do: state
  end

  @valid_kinds [:page, :submenu, :category_archive, :home]

  def get_menu(project_id) do
    project = Projects.get_project!(project_id)
    {:ok, load_menu(project)}
  end

  def update_menu(project_id, items) do
    project = Projects.get_project!(project_id)
    menu = %{items: normalize_menu_items(items)}
    :ok = write_menu_file(project, menu)
    {:ok, menu}
  end

  def sync_menu_from_filesystem(project_id) do
    project = Projects.get_project!(project_id)
    menu = load_menu(project)
    :ok = write_menu_file(project, menu)
    {:ok, menu}
  end

  defp load_menu(project) do
    case File.read(menu_path(project)) do
      {:ok, contents} ->
        %{items: parse_opml(contents) |> normalize_menu_items()}

      {:error, :enoent} ->
        %{items: normalize_menu_items([])}
    end
  end

  defp write_menu_file(project, menu) do
    path = menu_path(project)
    :ok = Persistence.atomic_write(path, serialize_opml(project, menu.items))
  end

  defp menu_path(project) do
    Path.join([Projects.project_data_dir(project), "meta", "menu.opml"])
  end

  defp normalize_menu_items(items) do
    without_home =
      items
      |> Enum.map(&normalize_menu_item/1)
      |> Enum.reject(&(&1.kind == :home))

    [%{kind: :home, label: "Home", slug: nil} | without_home]
  end

  defp normalize_menu_item(item) do
    kind = normalize_kind(attr(item, :kind))
    children = attr(item, :children)

    base = %{
      kind: kind,
      label: attr(item, :label) || "",
      slug: normalize_optional_string(attr(item, :slug))
    }

    if kind == :submenu do
      Map.put(base, :children, Enum.map(children || [], &normalize_menu_item/1))
    else
      base
    end
  end

  defp serialize_opml(project, items) do
    timestamp = project.updated_at || project.created_at || Persistence.now_ms()

    rendered_items =
      items
      |> Enum.map(&render_item(&1, 2))
      |> Enum.join("\n")

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<opml version="2.0">),
      ~s(  <head>),
      ~s(    <title>#{xml_escape(project.name)}</title>),
      ~s(    <dateCreated>#{Persistence.timestamp_to_iso8601(timestamp)}</dateCreated>),
      ~s(    <dateModified>#{Persistence.timestamp_to_iso8601(timestamp)}</dateModified>),
      ~s(  </head>),
      ~s(  <body>),
      rendered_items,
      ~s(  </body>),
      ~s(</opml>),
      ""
    ]
    |> Enum.join("\n")
  end

  defp render_item(item, level) do
    indent = String.duplicate("  ", level)
    attrs = render_attributes(item)

    case Map.get(item, :children) do
      children when is_list(children) and children != [] ->
        child_markup =
          children
          |> Enum.map(&render_item(&1, level + 1))
          |> Enum.join("\n")

        [
          "#{indent}<outline#{attrs}>",
          child_markup,
          "#{indent}</outline>"
        ]
        |> Enum.join("\n")

      _children ->
        "#{indent}<outline#{attrs} />"
    end
  end

  defp render_attributes(item) do
    item
    |> render_outline_attributes()
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map_join("", fn {key, value} -> ~s( #{key}="#{xml_escape(to_string(value))}") end)
  end

  defp parse_opml(contents) do
    case Saxy.parse_string(contents, OpmlHandler, %{path: [], stack: [], outlines: []}) do
      {:ok, %{outlines: outlines}} ->
        outlines
        |> Enum.reverse()
        |> Enum.map(&parse_outline/1)

      {:error, error} ->
        raise RuntimeError, "Invalid OPML menu file: #{Exception.message(error)}"
    end
  end

  defp parse_outline({attrs, children}) do
    kind = attrs |> outline_kind() |> normalize_kind()

    base = %{
      kind: kind,
      label: Map.get(attrs, "text") || "",
      slug: attrs |> outline_slug(kind) |> normalize_optional_string()
    }

    if kind == :submenu do
      Map.put(base, :children, Enum.map(children, &parse_outline/1))
    else
      base
    end
  end

  defp render_outline_attributes(item) do
    kind = Map.get(item, :kind)

    [
      {"text", item.label},
      {"type", render_outline_kind(kind)},
      {"pageSlug", render_page_slug(kind, item.slug)},
      {"categoryName", render_category_name(kind, item.slug)}
    ]
  end

  defp outline_kind(attrs), do: Map.get(attrs, "type") || Map.get(attrs, "kind")

  defp outline_slug(attrs, :category_archive),
    do: Map.get(attrs, "categoryName") || Map.get(attrs, "slug")

  defp outline_slug(attrs, _kind), do: Map.get(attrs, "pageSlug") || Map.get(attrs, "slug")

  defp render_outline_kind(:category_archive), do: "category-archive"
  defp render_outline_kind(kind), do: to_string(kind)

  defp render_page_slug(:home, _slug), do: "home"
  defp render_page_slug(kind, slug) when kind in [:page], do: slug
  defp render_page_slug(_kind, _slug), do: nil

  defp render_category_name(:category_archive, slug), do: slug
  defp render_category_name(_kind, _slug), do: nil

  defp normalize_kind(kind) when is_atom(kind) and kind in @valid_kinds, do: kind

  defp normalize_kind(nil), do: :page

  defp normalize_kind(kind) when is_binary(kind) do
    BDS.BoundedAtoms.menu_kind(kind, :page)
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s("), "&quot;")
  end

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
