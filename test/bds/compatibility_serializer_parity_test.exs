defmodule BDS.CompatibilitySerializerParityTest do
  use ExUnit.Case, async: true

  test "post frontmatter serialization matches old bDS output" do
    rendered =
      BDS.Frontmatter.serialize_document(
        [
          {"id", "post-1"},
          {"title", "Published Post"},
          {"slug", "published-post"},
          {"excerpt", "Summary"},
          {"status", :published},
          {"author", "Writer"},
          {"language", "en"},
          {"doNotTranslate", true},
          {"templateSlug", "article"},
          {"createdAt", 1_711_833_600_000},
          {"updatedAt", 1_711_920_000_000},
          {"publishedAt", 1_712_006_400_000},
          {"tags", ["alpha"]},
          {"categories", ["notes"]}
        ],
        "Hello from markdown"
      )

    assert rendered ==
             [
               "---",
               "id: post-1",
               "title: Published Post",
               "slug: published-post",
               "excerpt: Summary",
               "status: published",
               "author: Writer",
               "language: en",
               "doNotTranslate: true",
               "templateSlug: article",
               "createdAt: '2024-03-30T21:20:00.000Z'",
               "updatedAt: '2024-03-31T21:20:00.000Z'",
               "publishedAt: '2024-04-01T21:20:00.000Z'",
               "tags:",
               "  - alpha",
               "categories:",
               "  - notes",
               "---",
               "Hello from markdown",
               ""
             ]
             |> Enum.join("\n")
  end

  test "media sidecar serialization matches old bDS output" do
    rendered =
      BDS.Sidecar.serialize_document([
        {"id", "media-from-file"},
        {"originalName", "original.jpg"},
        {"mimeType", "image/jpeg"},
        {"size", 123},
        {"width", 3},
        {"height", 2},
        {"title", "Recovered"},
        {"alt", "Recovered alt"},
        {"caption", "Recovered caption"},
        {"author", "Writer"},
        {"language", "en"},
        {"createdAt", 1_711_833_600_000},
        {"updatedAt", 1_711_920_000_000},
        {"tags", ["alpha"]},
        {"linkedPostIds", ["post-a"]}
      ])

    assert rendered ==
             [
               "---",
               "id: media-from-file",
               "originalName: \"original.jpg\"",
               "mimeType: image/jpeg",
               "size: 123",
               "width: 3",
               "height: 2",
               "title: \"Recovered\"",
               "alt: \"Recovered alt\"",
               "caption: \"Recovered caption\"",
               "author: \"Writer\"",
               "language: en",
               "createdAt: 2024-03-30T21:20:00.000Z",
               "updatedAt: 2024-03-31T21:20:00.000Z",
               "tags: [\"alpha\"]",
               "linkedPostIds: [\"post-a\"]",
               "---"
             ]
             |> Enum.join("\n")
  end

  test "media sidecar parsing accepts old bDS inline arrays and document markers" do
    contents =
      [
        "---",
        "id: media-from-file",
        "originalName: \"original.jpg\"",
        "mimeType: image/jpeg",
        "size: 123",
        "width: 3",
        "height: 2",
        "title: \"Recovered\"",
        "alt: \"Recovered alt\"",
        "caption: \"Recovered caption\"",
        "author: \"Writer\"",
        "language: en",
        "createdAt: 2024-03-30T21:20:00.000Z",
        "updatedAt: 2024-03-31T21:20:00.000Z",
        "tags: [\"alpha\", \"beta\"]",
        "linkedPostIds: [\"post-a\", \"post-b\"]",
        "---"
      ]
      |> Enum.join("\n")

    assert {:ok, fields} = BDS.Sidecar.parse_document(contents)

    assert fields == %{
             "id" => "media-from-file",
             "originalName" => "original.jpg",
             "mimeType" => "image/jpeg",
             "size" => 123,
             "width" => 3,
             "height" => 2,
             "title" => "Recovered",
             "alt" => "Recovered alt",
             "caption" => "Recovered caption",
             "author" => "Writer",
             "language" => "en",
             "createdAt" => 1_711_833_600_000,
             "updatedAt" => 1_711_920_000_000,
             "tags" => ["alpha", "beta"],
             "linkedPostIds" => ["post-a", "post-b"]
           }
  end
end
