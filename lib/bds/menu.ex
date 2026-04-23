defmodule BDS.Menu do
  @moduledoc false

  require Record

  alias BDS.Projects

  Record.defrecord(:xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecord(:xmlAttribute, Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl"))

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
    meta_dir = Path.dirname(menu_path(project))
    :ok = File.mkdir_p(meta_dir)

    path = menu_path(project)
    temp_path = path <> ".tmp"

    :ok = File.write(temp_path, serialize_opml(menu.items))
    File.rename(temp_path, path)
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

  defp serialize_opml(items) do
    rendered_items =
      items
      |> Enum.map(&render_item(&1, 2))
      |> Enum.join("\n")

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<opml version="2.0">),
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
    [
      {"kind", item.kind},
      {"text", item.label},
      {"slug", item.slug}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map_join("", fn {key, value} -> ~s( #{key}="#{xml_escape(to_string(value))}") end)
  end

  defp parse_opml(contents) do
    {document, _rest} = :xmerl_scan.string(String.to_charlist(contents))

    :xmerl_xpath.string(~c"/opml/body/outline", document)
    |> Enum.map(&parse_outline/1)
  end

  defp parse_outline(element) do
    kind = element |> xml_attr(:kind) |> normalize_kind()

    base = %{
      kind: kind,
      label: xml_attr(element, :text) || "",
      slug: normalize_optional_string(xml_attr(element, :slug))
    }

    children =
      :xmerl_xpath.string(~c"./outline", element)
      |> Enum.map(&parse_outline/1)

    if kind == :submenu do
      Map.put(base, :children, children)
    else
      base
    end
  end

  defp xml_attr(element, name) do
    element
    |> xmlElement(:attributes)
    |> Enum.find_value(fn attribute ->
      if xmlAttribute(attribute, :name) == name do
        attribute |> xmlAttribute(:value) |> to_string()
      end
    end)
  end

  defp normalize_kind(kind) when is_atom(kind) and kind in @valid_kinds, do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    kind
    |> String.to_existing_atom()
    |> normalize_kind()
  rescue
    _error -> :page
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value), do: to_string(value)

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s(") , "&quot;")
  end

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end