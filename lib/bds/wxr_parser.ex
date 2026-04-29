defmodule BDS.WxrParser do
  @moduledoc false

  require Record

  Record.defrecord(:xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecord(:xmlAttribute, Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecord(:xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))

  def parse_file(file_path) when is_binary(file_path) do
    file_path
    |> File.read!()
    |> parse_xml()
  end

  def parse_xml(xml_content) when is_binary(xml_content) do
    {document, _rest} = :xmerl_scan.string(String.to_charlist(xml_content))

    case :xmerl_xpath.string(~c"/rss/channel", document) do
      [channel] ->
        %{
          site: parse_site(channel),
          posts: parse_items(channel, "post"),
          pages: parse_items(channel, "page"),
          media: parse_media(channel),
          categories: parse_categories(channel),
          tags: parse_tags(channel)
        }

      _other ->
        raise RuntimeError, "Invalid WXR file: no <channel> element found"
    end
  end

  defp parse_site(channel) do
    %{
      title: child_text(channel, "title"),
      link: child_text(channel, "link"),
      description: child_text(channel, "description"),
      language: child_text(channel, "language")
    }
  end

  defp parse_categories(channel) do
    channel
    |> direct_children()
    |> Enum.filter(&(full_name(&1) == "wp:category"))
    |> Enum.map(fn element ->
      %{
        name: child_text(element, "cat_name"),
        slug: child_text(element, "category_nicename"),
        parent: child_text(element, "category_parent")
      }
    end)
  end

  defp parse_tags(channel) do
    channel
    |> direct_children()
    |> Enum.filter(&(full_name(&1) == "wp:tag"))
    |> Enum.map(fn element ->
      %{
        name: child_text(element, "tag_name"),
        slug: child_text(element, "tag_slug")
      }
    end)
  end

  defp parse_items(channel, expected_type) do
    channel
    |> direct_children_named("item")
    |> Enum.filter(&(child_text(&1, "post_type") == expected_type))
    |> Enum.map(&parse_post_item/1)
  end

  defp parse_media(channel) do
    channel
    |> direct_children_named("item")
    |> Enum.filter(&(child_text(&1, "post_type") == "attachment"))
    |> Enum.map(&parse_media_item/1)
  end

  defp parse_post_item(item) do
    %{
      wp_id: parse_integer(child_text(item, "post_id")),
      title: child_text(item, "title"),
      slug: child_text(item, "post_name"),
      content: child_text_by_full_name(item, "content:encoded"),
      excerpt: child_text_by_full_name(item, "excerpt:encoded"),
      pub_date: blank_to_nil(child_text(item, "pubDate")),
      post_date: blank_to_nil(child_text(item, "post_date")),
      post_modified: blank_to_nil(child_text(item, "post_modified")),
      creator: child_text_by_full_name(item, "dc:creator"),
      status: child_text(item, "status"),
      post_type: child_text(item, "post_type"),
      categories: item_taxonomy(item, "category"),
      tags: item_taxonomy(item, "post_tag")
    }
  end

  defp parse_media_item(item) do
    attachment_url = child_text(item, "attachment_url")
    filename = attachment_url |> Path.basename() |> blank_to_nil() || ""

    %{
      wp_id: parse_integer(child_text(item, "post_id")),
      title: child_text(item, "title"),
      url: attachment_url,
      filename: filename,
      relative_path: relative_upload_path(attachment_url),
      pub_date: blank_to_nil(child_text(item, "pubDate")),
      parent_id: parse_integer(child_text(item, "post_parent")),
      mime_type: MIME.from_path(filename),
      description: child_text_by_full_name(item, "content:encoded")
    }
  end

  defp item_taxonomy(item, domain) do
    item
    |> direct_children_named("category")
    |> Enum.filter(&(xml_attr(&1, :domain) == domain))
    |> Enum.map(&text_content/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp relative_upload_path(url) when is_binary(url) do
    marker = "/wp-content/uploads/"

    case String.split(url, marker, parts: 2) do
      [_prefix, suffix] -> suffix
      _other -> Path.basename(url)
    end
  end

  defp direct_children(element) do
    Enum.filter(xmlElement(element, :content), fn child ->
      is_tuple(child) and tuple_size(child) > 0 and elem(child, 0) == :xmlElement
    end)
  end

  defp direct_children_named(element, name) do
    Enum.filter(direct_children(element), &(local_name(&1) == name))
  end

  defp child_text(element, name) do
    element
    |> direct_children_named(name)
    |> List.first()
    |> text_content()
  end

  defp child_text_by_full_name(element, name) do
    element
    |> direct_children()
    |> Enum.find(&(full_name(&1) == name))
    |> text_content()
  end

  defp text_content(nil), do: ""

  defp text_content(element) do
    element
    |> xmlElement(:content)
    |> Enum.map_join("", fn
      child when is_tuple(child) and tuple_size(child) > 0 and elem(child, 0) == :xmlText ->
        child
        |> xmlText(:value)
        |> to_string()

      child when is_tuple(child) and tuple_size(child) > 0 and elem(child, 0) == :xmlElement ->
        text_content(child)

      _other -> ""
    end)
    |> String.trim()
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

  defp full_name(element), do: element |> xmlElement(:name) |> to_string()

  defp local_name(element) do
    element
    |> full_name()
    |> String.split(":")
    |> List.last()
  end

  defp parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
