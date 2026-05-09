defmodule BDS.CSM015MissingIndexesTest do
  use ExUnit.Case, async: false

  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    :ok
  end

  defp uses_index?(sql) do
    {:ok, result} = Ecto.Adapters.SQL.query(Repo, "EXPLAIN QUERY PLAN #{sql}", [])

    Enum.any?(result.rows, fn row ->
      detail = List.last(row)
      is_binary(detail) and String.contains?(detail, "INDEX")
    end)
  end

  describe "foreign key indexes" do
    test "media.project_id is indexed" do
      assert uses_index?("SELECT id FROM media WHERE project_id = 'test'")
    end

    test "post_media.post_id is indexed" do
      assert uses_index?("SELECT id FROM post_media WHERE post_id = 'test'")
    end

    test "post_media.media_id is indexed" do
      assert uses_index?("SELECT id FROM post_media WHERE media_id = 'test'")
    end

    test "chat_messages.conversation_id is indexed" do
      assert uses_index?("SELECT id FROM chat_messages WHERE conversation_id = 'test'")
    end

    test "embedding_keys.post_id is indexed" do
      assert uses_index?("SELECT label FROM embedding_keys WHERE post_id = 'test'")
    end

    test "embedding_keys.project_id is indexed" do
      assert uses_index?("SELECT label FROM embedding_keys WHERE project_id = 'test'")
    end

    test "dismissed_duplicate_pairs.project_id is indexed" do
      assert uses_index?("SELECT id FROM dismissed_duplicate_pairs WHERE project_id = 'test'")
    end

    test "import_definitions.project_id is indexed" do
      assert uses_index?("SELECT id FROM import_definitions WHERE project_id = 'test'")
    end
  end

  describe "frequently filtered columns" do
    test "posts.status is indexed" do
      assert uses_index?("SELECT id FROM posts WHERE status = 'published'")
    end

    test "posts.published_at is indexed" do
      assert uses_index?("SELECT id FROM posts WHERE published_at > 0")
    end

    test "posts.language is indexed" do
      assert uses_index?("SELECT id FROM posts WHERE language = 'en'")
    end
  end

  describe "db_notifications lookup" do
    test "db_notifications entity_type + entity_id is indexed" do
      assert uses_index?(
               "SELECT id FROM db_notifications WHERE entity_type = 'post' AND entity_id = 'test'"
             )
    end
  end
end
