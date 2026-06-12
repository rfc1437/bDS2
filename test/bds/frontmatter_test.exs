defmodule BDS.FrontmatterTest do
  use ExUnit.Case, async: true

  test "parse_document accepts CRLF frontmatter documents" do
    contents = "---\r\ntitle: Hello\r\ntags:\r\n  - elixir\r\n---\r\nBody\r\n"

    assert {:ok, %{fields: fields, body: body}} = BDS.Frontmatter.parse_document(contents)
    assert fields["title"] == "Hello"
    assert fields["tags"] == ["elixir"]
    assert body == "Body"
  end

  test "serialize_document roundtrips quoted strings with embedded quotes and escapes" do
    fields = [
      {"title", "He said \"hi\" \\\\ there"},
      {"summary", "Ends with a quote\""},
      {"excerpt", "first line\nsecond line"}
    ]

    contents = BDS.Frontmatter.serialize_document(fields, "Body")

    assert {:ok, %{fields: parsed_fields, body: body}} =
             BDS.Frontmatter.parse_document(contents)

    assert parsed_fields["title"] == "He said \"hi\" \\\\ there"
    assert parsed_fields["summary"] == "Ends with a quote\""
    assert parsed_fields["excerpt"] == "first line\nsecond line"
    assert body == "Body"
  end
end