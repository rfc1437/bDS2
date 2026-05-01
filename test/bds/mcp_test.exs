defmodule BDS.MCPTest do
  use ExUnit.Case, async: false

  alias BDS.Media.Media
  alias BDS.MCP.ProposalStore
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
    tool_names =
      BDS.MCP.list_tools()
      |> Enum.map(& &1.name)

    assert "check_term" in tool_names
    assert "search_posts" in tool_names
    assert "count_posts" in tool_names
    assert "read_post_by_slug" in tool_names
    assert "draft_post" in tool_names
    assert "propose_script" in tool_names
    assert "propose_template" in tool_names
    assert "propose_media_metadata" in tool_names
    assert "propose_post_metadata" in tool_names
    assert "accept_proposal" in tool_names
    assert "discard_proposal" in tool_names
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
end
