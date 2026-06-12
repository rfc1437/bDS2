defmodule BDS.WxrParser do
  @moduledoc false

  defmodule ParserState do
    @moduledoc false

    defstruct stack: [],
              channel_seen?: false,
              site: %{title: "", link: "", description: "", language: ""},
              categories: [],
              tags: [],
              items: [],
              current_category: nil,
              current_tag: nil,
              current_item: nil,
              current_taxonomy: nil,
              text: ""
  end

  defmodule Handler do
    @moduledoc false

    @behaviour Saxy.Handler

    alias BDS.WxrParser.ParserState

    def handle_event(:start_document, _prolog, state), do: {:ok, state}

    def handle_event(:end_document, _data, state), do: {:ok, state}

    def handle_event(:characters, chars, state) do
      {:ok, %{state | text: state.text <> chars}}
    end

    def handle_event(:start_element, {name, attributes}, state) do
      parent = current_name(state)

      state =
        state
        |> push_name(name)
        |> reset_text()
        |> maybe_start_channel(parent, name)
        |> maybe_start_category(parent, name)
        |> maybe_start_tag(parent, name)
        |> maybe_start_item(parent, name)
        |> maybe_start_item_taxonomy(parent, name, attributes)

      {:ok, state}
    end

    def handle_event(:end_element, name, state) do
      parent = parent_name(state)
      text = String.trim(state.text)

      state =
        state
        |> maybe_capture_site_field(parent, name, text)
        |> maybe_capture_category_field(parent, name, text)
        |> maybe_finish_category(parent, name)
        |> maybe_capture_tag_field(parent, name, text)
        |> maybe_finish_tag(parent, name)
        |> maybe_capture_item_field(parent, name, text)
        |> maybe_finish_item_taxonomy(parent, name, text)
        |> maybe_finish_item(parent, name)
        |> pop_name()
        |> reset_text()

      {:ok, state}
    end

    defp current_name(%ParserState{stack: [name | _rest]}), do: name
    defp current_name(%ParserState{}), do: nil

    defp parent_name(%ParserState{stack: [_current, parent | _rest]}), do: parent
    defp parent_name(%ParserState{}), do: nil

    defp push_name(state, name), do: %{state | stack: [name | state.stack]}

    defp pop_name(%ParserState{stack: [_name | rest]} = state), do: %{state | stack: rest}
    defp pop_name(state), do: state

    defp reset_text(state), do: %{state | text: ""}

    defp maybe_start_channel(state, "rss", "channel"), do: %{state | channel_seen?: true}
    defp maybe_start_channel(state, _parent, _name), do: state

    defp maybe_start_category(state, "channel", "wp:category") do
      %{state | current_category: %{name: "", slug: "", parent: ""}}
    end

    defp maybe_start_category(state, _parent, _name), do: state

    defp maybe_start_tag(state, "channel", "wp:tag") do
      %{state | current_tag: %{name: "", slug: ""}}
    end

    defp maybe_start_tag(state, _parent, _name), do: state

    defp maybe_start_item(state, "channel", "item") do
      %{state | current_item: empty_item()}
    end

    defp maybe_start_item(state, _parent, _name), do: state

    defp maybe_start_item_taxonomy(state, "item", "category", attributes) do
      %{state | current_taxonomy: %{domain: attribute_value(attributes, "domain")}}
    end

    defp maybe_start_item_taxonomy(state, _parent, _name, _attributes), do: state

    defp maybe_capture_site_field(
           %ParserState{current_category: nil, current_tag: nil, current_item: nil} = state,
           "channel",
           name,
           text
         ) do
      case name do
        "title" -> put_in(state.site.title, text)
        "link" -> put_in(state.site.link, text)
        "description" -> put_in(state.site.description, text)
        "language" -> put_in(state.site.language, text)
        _other -> state
      end
    end

    defp maybe_capture_site_field(state, _parent, _name, _text), do: state

    defp maybe_capture_category_field(%ParserState{current_category: nil} = state, _parent, _name, _text),
      do: state

    defp maybe_capture_category_field(%ParserState{} = state, "wp:category", name, text) do
      key =
        case name do
          "wp:cat_name" -> :name
          "wp:category_nicename" -> :slug
          "wp:category_parent" -> :parent
          _other -> nil
        end

      if key do
        update_in(state.current_category, &Map.put(&1, key, text))
      else
        state
      end
    end

    defp maybe_capture_category_field(state, _parent, _name, _text), do: state

    defp maybe_finish_category(%ParserState{current_category: nil} = state, _parent, _name), do: state

    defp maybe_finish_category(%ParserState{} = state, "channel", "wp:category") do
      %{state | categories: [state.current_category | state.categories], current_category: nil}
    end

    defp maybe_finish_category(state, _parent, _name), do: state

    defp maybe_capture_tag_field(%ParserState{current_tag: nil} = state, _parent, _name, _text),
      do: state

    defp maybe_capture_tag_field(%ParserState{} = state, "wp:tag", name, text) do
      key =
        case name do
          "wp:tag_name" -> :name
          "wp:tag_slug" -> :slug
          _other -> nil
        end

      if key do
        update_in(state.current_tag, &Map.put(&1, key, text))
      else
        state
      end
    end

    defp maybe_capture_tag_field(state, _parent, _name, _text), do: state

    defp maybe_finish_tag(%ParserState{current_tag: nil} = state, _parent, _name), do: state

    defp maybe_finish_tag(%ParserState{} = state, "channel", "wp:tag") do
      %{state | tags: [state.current_tag | state.tags], current_tag: nil}
    end

    defp maybe_finish_tag(state, _parent, _name), do: state

    defp maybe_capture_item_field(%ParserState{current_item: nil} = state, _parent, _name, _text),
      do: state

    defp maybe_capture_item_field(%ParserState{} = state, "item", name, text) do
      key =
        case name do
          "title" -> :title
          "pubDate" -> :pub_date
          "dc:creator" -> :creator
          "content:encoded" -> :content
          "excerpt:encoded" -> :excerpt
          "wp:post_id" -> :post_id
          "wp:post_date" -> :post_date
          "wp:post_modified" -> :post_modified
          "wp:post_name" -> :post_name
          "wp:status" -> :status
          "wp:post_type" -> :post_type
          "wp:post_parent" -> :post_parent
          "wp:attachment_url" -> :attachment_url
          _other -> nil
        end

      if key do
        update_in(state.current_item, &Map.put(&1, key, text))
      else
        state
      end
    end

    defp maybe_capture_item_field(state, _parent, _name, _text), do: state

    defp maybe_finish_item_taxonomy(
           %ParserState{current_item: nil, current_taxonomy: nil} = state,
           _parent,
           _name,
           _text
         ),
         do: state

    defp maybe_finish_item_taxonomy(%ParserState{current_taxonomy: nil} = state, _parent, _name, _text),
      do: state

    defp maybe_finish_item_taxonomy(%ParserState{} = state, "item", "category", text) do
      domain = Map.get(state.current_taxonomy, :domain)

      state =
        cond do
          text == "" -> state
          domain == "category" -> update_in(state.current_item.categories, &(&1 ++ [text]))
          domain == "post_tag" -> update_in(state.current_item.tags, &(&1 ++ [text]))
          true -> state
        end

      %{state | current_taxonomy: nil}
    end

    defp maybe_finish_item_taxonomy(state, _parent, _name, _text), do: state

    defp maybe_finish_item(%ParserState{current_item: nil} = state, _parent, _name), do: state

    defp maybe_finish_item(%ParserState{} = state, "channel", "item") do
      %{state | items: [state.current_item | state.items], current_item: nil}
    end

    defp maybe_finish_item(state, _parent, _name), do: state

    defp empty_item do
      %{
        post_id: "",
        title: "",
        post_name: "",
        content: "",
        excerpt: "",
        pub_date: "",
        post_date: "",
        post_modified: "",
        creator: "",
        status: "",
        post_type: "",
        post_parent: "",
        attachment_url: "",
        categories: [],
        tags: []
      }
    end

    defp attribute_value(attributes, name) do
      Enum.find_value(attributes, fn
        {^name, value} -> value
        _other -> nil
      end)
    end
  end

  def parse_file(file_path) when is_binary(file_path) do
    file_path
    |> File.stream!(32_768, [])
    |> parse_document(&Saxy.parse_stream(&1, Handler, %ParserState{}))
  end

  def parse_xml(xml_content) when is_binary(xml_content) do
    xml_content
    |> parse_document(&Saxy.parse_string(&1, Handler, %ParserState{}))
  end

  defp parse_document(input, parser) do
    case parser.(input) do
      {:ok, %ParserState{channel_seen?: true} = state} ->
        build_result(state)

      {:ok, %ParserState{channel_seen?: false}} ->
        raise RuntimeError, "Invalid WXR file: no <channel> element found"

      {:error, error} ->
        raise RuntimeError, Exception.message(error)
    end
  end

  defp build_result(%ParserState{} = state) do
    items = Enum.reverse(state.items)

    %{
      site: state.site,
      posts:
        items
        |> Enum.filter(fn item -> item.post_type not in ["", "attachment", "page"] end)
        |> Enum.map(&parse_post_item/1),
      pages:
        items
        |> Enum.filter(&(&1.post_type == "page"))
        |> Enum.map(&parse_post_item/1),
      media:
        items
        |> Enum.filter(&(&1.post_type == "attachment"))
        |> Enum.map(&parse_media_item/1),
      categories: Enum.reverse(state.categories),
      tags: Enum.reverse(state.tags)
    }
  end

  defp parse_post_item(item) do
    %{
      wp_id: parse_integer(item.post_id),
      title: item.title,
      slug: item.post_name,
      content: item.content,
      excerpt: item.excerpt,
      pub_date: blank_to_nil(item.pub_date),
      post_date: blank_to_nil(item.post_date),
      post_modified: blank_to_nil(item.post_modified),
      creator: item.creator,
      status: item.status,
      post_type: item.post_type,
      categories: Enum.reject(item.categories, &(&1 == "")),
      tags: Enum.reject(item.tags, &(&1 == ""))
    }
  end

  defp parse_media_item(item) do
    attachment_url = item.attachment_url
    filename = attachment_url |> Path.basename() |> blank_to_nil() || ""

    %{
      wp_id: parse_integer(item.post_id),
      title: item.title,
      url: attachment_url,
      filename: filename,
      relative_path: relative_upload_path(attachment_url),
      pub_date: blank_to_nil(item.pub_date),
      parent_id: parse_integer(item.post_parent),
      mime_type: MIME.from_path(filename),
      description: item.content
    }
  end

  defp relative_upload_path(url) when is_binary(url) do
    marker = "/wp-content/uploads/"

    case String.split(url, marker, parts: 2) do
      [_prefix, suffix] -> suffix
      _other -> Path.basename(url)
    end
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
