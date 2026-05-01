defmodule BDS.MCPTest do
  use ExUnit.Case, async: false

  alias BDS.Media.Media
  alias BDS.MCP.ProposalStore
  alias BDS.Posts.Post
  alias BDS.Repo
  alias BDS.Scripts.Script
  alias BDS.Templates.Template

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir = Path.join(System.tmp_dir!(), "bds-mcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "MCP", data_path: temp_dir})
    {:ok, _active} = BDS.Projects.set_active_project(project.id)

    %{project: project, temp_dir: temp_dir}
  end

  test "list_tools follows the old app tool surface for implemented backend features" do
    tools = BDS.MCP.list_tools()
    tool_names = Enum.map(tools, & &1.name)

    assert "check_term" in tool_names
    assert "search_posts" in tool_names
    assert "count_posts" in tool_names
    assert "read_post_by_slug" in tool_names
    assert "get_post_translations" in tool_names
    assert "get_media_translations" in tool_names
    assert "upsert_media_translation" in tool_names
    assert "draft_post" in tool_names
    assert "propose_script" in tool_names
    assert "propose_template" in tool_names
    assert "propose_media_metadata" in tool_names
    assert "propose_post_metadata" in tool_names
    assert "accept_proposal" in tool_names
    assert "discard_proposal" in tool_names

    search_posts = Enum.find(tools, &(&1.name == "search_posts"))
    assert search_posts.title == "Search Posts"
    assert search_posts.description =~ "paginated envelope"
    assert search_posts.description =~ "backlinks"
    assert get_in(search_posts.inputSchema, ["properties", "query", "description"]) =~ "Full-text"
    assert get_in(search_posts.inputSchema, ["properties", "tags", "items", "type"]) == "string"
    assert search_posts.annotations["readOnlyHint"] == true
    assert search_posts.annotations["openWorldHint"] == false

    draft_post = Enum.find(tools, &(&1.name == "draft_post"))
    assert draft_post.description =~ "draft blog post"
    assert draft_post.inputSchema["required"] == ["title", "content"]
    assert draft_post.annotations["readOnlyHint"] == false
  end

  test "check_term, search_posts, count_posts, and read_post_by_slug expose current blog data", %{
    project: project
  } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Travel Notes",
               content: "Travel through Berlin",
               language: "en",
               tags: ["travel"],
               categories: ["article"]
             })

    assert {:ok, _published} = BDS.Posts.publish_post(post.id)
    assert {:ok, _tags} = BDS.Tags.sync_tags_from_posts(project.id)

    assert {:ok, term_result} = BDS.MCP.call_tool("check_term", %{term: "travel"})
    assert term_result["is_tag"] == true
    assert term_result["tag_post_count"] == 1
    assert term_result["is_category"] == false

    assert {:ok, search_result} = BDS.MCP.call_tool("search_posts", %{query: "Berlin"})
    assert search_result["total"] == 1
    assert [%{"slug" => "travel-notes"}] = search_result["posts"]

    assert {:ok, count_result} = BDS.MCP.call_tool("count_posts", %{groupBy: ["tag"]})
    assert count_result["total_posts"] == 1
    assert Enum.any?(count_result["groups"], &(&1["tag"] == "travel" and &1["count"] == 1))

    assert {:ok, read_result} = BDS.MCP.call_tool("read_post_by_slug", %{slug: "travel-notes"})
    assert read_result["post"]["title"] == "Travel Notes"
    assert read_result["post"]["slug"] == "travel-notes"
  end

  test "count_posts groups every matching post before returning groups", %{project: project} do
    month_counts = [{2, 24}, {3, 26}, {4, 23}]

    for {month, count} <- month_counts,
        index <- 1..count do
      day = rem(index - 1, 28) + 1
      created_at = unix_ms!(NaiveDateTime.new!(Date.new!(2026, month, day), ~T[12:00:00]))

      Repo.insert!(
        Post.changeset(%Post{}, %{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          title: "MCP Count #{month}-#{index}",
          slug: "mcp-count-#{month}-#{index}",
          content: "Body",
          status: :draft,
          created_at: created_at,
          updated_at: created_at,
          do_not_translate: false
        })
      )
    end

    assert {:ok, %{"groups" => groups, "total_posts" => 73}} =
             BDS.MCP.call_tool("count_posts", %{groupBy: ["month"], year: 2026})

    assert Enum.sort_by(groups, & &1["month"]) == [
             %{"count" => 24, "month" => 2},
             %{"count" => 26, "month" => 3},
             %{"count" => 23, "month" => 4}
           ]
  end

  test "translation tools expose post and media translations and upsert media metadata", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Translatable Post",
               content: "Source body",
               language: "en"
             })

    assert {:ok, _post_translation} =
             BDS.Posts.upsert_post_translation(post.id, "de", %{
               title: "Ubersetzter Beitrag",
               excerpt: "Kurzfassung",
               content: "Ubersetzter Inhalt"
             })

    source_path = Path.join(temp_dir, "translation-media.txt")
    File.write!(source_path, "media body")

    assert {:ok, media} =
             BDS.Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Source Media",
               alt: "Source Alt",
               caption: "Source Caption",
               language: "en"
             })

    assert {:ok, post_result} =
             BDS.MCP.call_tool("get_post_translations", %{postId: post.id})

    assert [post_translation] = post_result["translations"]
    assert post_translation["language"] == "de"
    assert post_translation["title"] == "Ubersetzter Beitrag"
    assert post_translation["excerpt"] == "Kurzfassung"
    assert post_translation["content"] == "Ubersetzter Inhalt"
    assert post_translation["status"] == "draft"

    assert {:ok, upsert_result} =
             BDS.MCP.call_tool("upsert_media_translation", %{
               mediaId: media.id,
               language: "de",
               title: "Medientitel",
               alt: "Medien Alt",
               caption: "Medien Beschriftung"
             })

    assert upsert_result["translation"]["language"] == "de"
    assert upsert_result["translation"]["title"] == "Medientitel"

    assert {:ok, media_result} =
             BDS.MCP.call_tool("get_media_translations", %{mediaId: media.id})

    assert [media_translation] = media_result["translations"]
    assert media_translation["language"] == "de"
    assert media_translation["title"] == "Medientitel"
    assert media_translation["alt"] == "Medien Alt"
    assert media_translation["caption"] == "Medien Beschriftung"
  end

  test "proposal-backed write tools follow the old app lifecycle for scripts, templates, and metadata",
       %{
         project: project,
         temp_dir: temp_dir
       } do
    source_path = Path.join(temp_dir, "image.txt")
    File.write!(source_path, "image body")

    assert {:ok, media} =
             BDS.Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Old"
             })

    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Meta Post",
               content: "Body",
               language: "en"
             })

    assert {:ok, draft_result} =
             BDS.MCP.call_tool("draft_post", %{
               title: "Draft From MCP",
               content: "Draft body",
               tags: ["mcp"],
               categories: ["article"]
             })

    draft_proposal_id = draft_result["proposal_id"]
    draft_post_id = draft_result["post"]["id"]

    assert {:ok, _accepted} =
             BDS.MCP.call_tool("accept_proposal", %{proposalId: draft_proposal_id})

    assert BDS.Posts.get_post!(draft_post_id).status == :published

    assert {:ok, script_result} =
             BDS.MCP.call_tool("propose_script", %{
               title: "Example Script",
               kind: "utility",
               content: "function main() return 'ok' end"
             })

    script_id = script_result["script"]["id"]

    assert {:ok, _accepted_script} =
             BDS.MCP.call_tool("accept_proposal", %{proposalId: script_result["proposal_id"]})

    assert Repo.get!(Script, script_id).status == :published

    assert {:ok, template_result} =
             BDS.MCP.call_tool("propose_template", %{
               title: "Example Template",
               kind: "post",
               content: "<article>{{ post.title }}</article>"
             })

    template_id = template_result["template"]["id"]

    assert {:ok, _accepted_template} =
             BDS.MCP.call_tool("accept_proposal", %{proposalId: template_result["proposal_id"]})

    assert Repo.get!(Template, template_id).status == :published

    assert {:ok, media_proposal} =
             BDS.MCP.call_tool("propose_media_metadata", %{
               mediaId: media.id,
               title: "New Title",
               alt: "Alt Text"
             })

    assert {:ok, _accepted_media} =
             BDS.MCP.call_tool("accept_proposal", %{proposalId: media_proposal["proposal_id"]})

    updated_media = Repo.get!(Media, media.id)
    assert updated_media.title == "New Title"
    assert updated_media.alt == "Alt Text"

    assert {:ok, post_proposal} =
             BDS.MCP.call_tool("propose_post_metadata", %{
               postId: post.id,
               title: "Updated Title",
               excerpt: "Short excerpt"
             })

    assert {:ok, _accepted_post} =
             BDS.MCP.call_tool("accept_proposal", %{proposalId: post_proposal["proposal_id"]})

    updated_post = BDS.Posts.get_post!(post.id)
    assert updated_post.title == "Updated Title"
    assert updated_post.excerpt == "Short excerpt"
  end

  test "discard_proposal removes draft-backed entities" do
    assert {:ok, draft_result} =
             BDS.MCP.call_tool("draft_post", %{title: "Discard Me", content: "Body"})

    draft_post_id = draft_result["post"]["id"]

    assert {:ok, _discarded} =
             BDS.MCP.call_tool("discard_proposal", %{proposalId: draft_result["proposal_id"]})

    assert_raise Ecto.NoResultsError, fn -> BDS.Posts.get_post!(draft_post_id) end
  end

  test "proposal lifecycle removes accepted and discarded proposals" do
    assert {:ok, accepted_result} =
             BDS.MCP.call_tool("draft_post", %{title: "Accept Me", content: "Body"})

    accepted_id = accepted_result["proposal_id"]
    assert ProposalStore.get(accepted_id).status == :pending

    assert {:ok, _accepted} = BDS.MCP.call_tool("accept_proposal", %{proposalId: accepted_id})
    assert ProposalStore.get(accepted_id) == nil

    assert {:ok, discarded_result} =
             BDS.MCP.call_tool("draft_post", %{title: "Discard Me Later", content: "Body"})

    discarded_id = discarded_result["proposal_id"]
    assert {:ok, _discarded} = BDS.MCP.call_tool("discard_proposal", %{proposalId: discarded_id})
    assert ProposalStore.get(discarded_id) == nil

    expired =
      ProposalStore.create("draft_post", %{"post_id" => "expired-post"},
        entity_id: "expired-post",
        ttl_ms: -1
      )

    expired_proposals = ProposalStore.cleanup_expired()
    assert Enum.any?(expired_proposals, &(&1.id == expired.id and &1.status == :expired))
    assert ProposalStore.get(expired.id).status == :expired
  end

  test "resource listing and reads follow old app naming for implemented resources", %{
    project: project
  } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Resource Post",
               content: "Resource body",
               language: "en",
               tags: ["resources"],
               categories: ["article"]
             })

    assert {:ok, _published} = BDS.Posts.publish_post(post.id)
    assert {:ok, _tags} = BDS.Tags.sync_tags_from_posts(project.id)

    resource_uris = BDS.MCP.list_resources() |> Enum.map(& &1.uri)
    assert "bds://posts" in resource_uris
    assert "bds://media" in resource_uris
    assert "bds://tags" in resource_uris
    assert "bds://categories" in resource_uris

    assert {:ok, posts_resource} = BDS.MCP.read_resource("bds://posts")
    assert posts_resource["total"] == 1

    assert {:ok, post_resource} = BDS.MCP.read_resource("bds://posts/#{post.id}")
    assert post_resource["slug"] == "resource-post"
  end

  test "missing old app MCP resources expose stats, post media, and media image blobs", %{
    project: project,
    temp_dir: temp_dir
  } do
    assert {:ok, post} =
             BDS.Posts.create_post(%{
               project_id: project.id,
               title: "Media Resource Post",
               content: "Body",
               language: "en",
               tags: ["resources"],
               categories: ["article"]
             })

    assert {:ok, _published} = BDS.Posts.publish_post(post.id)
    assert {:ok, _tags} = BDS.Tags.sync_tags_from_posts(project.id)

    source_path = Path.join(temp_dir, "resource-image.png")
    image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, "not-a-real-png-but-served-as-bytes">>
    File.write!(source_path, image_bytes)

    assert {:ok, media} =
             BDS.Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Resource Image",
               alt: "Resource alt"
             })

    assert {:ok, :linked} = BDS.Media.link_media_to_post(media.id, post.id)

    resource_uris = BDS.MCP.list_resources() |> Enum.map(& &1.uri)
    assert "bds://stats" in resource_uris

    template_uris = BDS.MCP.list_resource_templates() |> Enum.map(& &1.uriTemplate)
    assert "bds://posts/{id}/media" in template_uris
    assert "bds://media/{id}/image" in template_uris

    assert {:ok, stats} = BDS.MCP.read_resource("bds://stats")
    assert stats["posts"] == 1
    assert stats["media"] == 1
    assert stats["tags"] == 1
    assert {:ok, categories} = BDS.MCP.read_resource("bds://categories")
    assert stats["categories"] == length(categories["items"])

    assert {:ok, post_media} = BDS.MCP.read_resource("bds://posts/#{post.id}/media")

    assert [%{"id" => media_id, "title" => "Resource Image", "alt" => "Resource alt"}] =
             post_media["items"]

    assert media_id == media.id

    assert {:ok, image_resource} = BDS.MCP.read_resource("bds://media/#{media.id}/image")
    assert image_resource["mimeType"] == "image/png"
    assert Base.decode64!(image_resource["blob"]) == image_bytes

    assert {:error, :not_found} = BDS.MCP.read_resource("bds://posts/missing/media")
    assert {:error, :not_found} = BDS.MCP.read_resource("bds://media/missing/image")
  end

  test "post resources use base64url cursors with 50 item pages", %{project: project} do
    for index <- 1..51 do
      assert {:ok, _post} =
               BDS.Posts.create_post(%{
                 project_id: project.id,
                 title: "Cursor Post #{String.pad_leading(to_string(index), 2, "0")}",
                 content: "Cursor body #{index}",
                 language: "en"
               })
    end

    assert {:ok, first_page} = BDS.MCP.read_resource("bds://posts")
    assert length(first_page["items"]) == 50
    assert first_page["nextCursor"] =~ ~r/^[A-Za-z0-9_-]+$/
    refute Map.has_key?(first_page, "has_more")

    assert {:ok, final_page} =
             BDS.MCP.read_resource("bds://posts?cursor=#{first_page["nextCursor"]}")

    assert length(final_page["items"]) == 1
    refute Map.has_key?(final_page, "nextCursor")
  end

  test "media resources use base64url cursors with 50 item pages", %{
    project: project,
    temp_dir: temp_dir
  } do
    for index <- 1..51 do
      source_path = Path.join(temp_dir, "cursor-media-#{index}.txt")
      File.write!(source_path, "media body #{index}")

      assert {:ok, _media} =
               BDS.Media.import_media(%{
                 project_id: project.id,
                 source_path: source_path,
                 title: "Cursor Media #{String.pad_leading(to_string(index), 2, "0")}"
               })
    end

    assert {:ok, first_page} = BDS.MCP.read_resource("bds://media")
    assert length(first_page["items"]) == 50
    assert first_page["nextCursor"] =~ ~r/^[A-Za-z0-9_-]+$/

    assert {:ok, final_page} =
             BDS.MCP.read_resource("bds://media?cursor=#{first_page["nextCursor"]}")

    assert length(final_page["items"]) == 1
    refute Map.has_key?(final_page, "nextCursor")
  end

  test "cursor resources reject invalid cursors and list URI templates" do
    assert {:error, :invalid_cursor} = BDS.MCP.read_resource("bds://posts?cursor=not-valid")
    assert {:error, :invalid_cursor} = BDS.MCP.read_resource("bds://media?cursor=not-valid")

    templates = BDS.MCP.list_resource_templates()
    template_uris = Enum.map(templates, & &1.uriTemplate)

    assert "bds://posts{?cursor}" in template_uris
    assert "bds://media{?cursor}" in template_uris
  end

  defp unix_ms!(%NaiveDateTime{} = naive_datetime) do
    naive_datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end
end
