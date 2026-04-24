defmodule BDS.Repo.SchemaMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
  end

  test "creates the persisted tables and columns declared by the schema spec" do
    expected_columns = %{
      "projects" => [
        "id",
        "name",
        "slug",
        "description",
        "data_path",
        "created_at",
        "updated_at",
        "is_active"
      ],
      "posts" => [
        "project_id",
        "id",
        "title",
        "slug",
        "excerpt",
        "content",
        "status",
        "author",
        "created_at",
        "updated_at",
        "published_at",
        "file_path",
        "checksum",
        "tags",
        "categories",
        "template_slug",
        "language",
        "do_not_translate",
        "published_title",
        "published_content",
        "published_tags",
        "published_categories",
        "published_excerpt"
      ],
      "post_translations" => [
        "id",
        "project_id",
        "translation_for",
        "language",
        "title",
        "excerpt",
        "content",
        "status",
        "created_at",
        "updated_at",
        "published_at",
        "file_path",
        "checksum"
      ],
      "media" => [
        "project_id",
        "id",
        "filename",
        "original_name",
        "mime_type",
        "size",
        "width",
        "height",
        "title",
        "alt",
        "caption",
        "author",
        "file_path",
        "sidecar_path",
        "created_at",
        "updated_at",
        "checksum",
        "tags",
        "language"
      ],
      "media_translations" => [
        "id",
        "project_id",
        "translation_for",
        "language",
        "title",
        "alt",
        "caption",
        "created_at",
        "updated_at"
      ],
      "tags" => [
        "id",
        "project_id",
        "name",
        "color",
        "post_template_slug",
        "created_at",
        "updated_at"
      ],
      "templates" => [
        "id",
        "project_id",
        "slug",
        "title",
        "kind",
        "enabled",
        "version",
        "file_path",
        "status",
        "content",
        "created_at",
        "updated_at"
      ],
      "scripts" => [
        "id",
        "project_id",
        "slug",
        "title",
        "kind",
        "entrypoint",
        "enabled",
        "version",
        "file_path",
        "status",
        "content",
        "created_at",
        "updated_at"
      ],
      "post_links" => ["id", "source_post_id", "target_post_id", "link_text", "created_at"],
      "post_media" => ["id", "project_id", "post_id", "media_id", "sort_order", "created_at"],
      "settings" => ["key", "value", "updated_at"],
      "generated_file_hashes" => ["project_id", "relative_path", "content_hash", "updated_at"],
      "chat_conversations" => [
        "id",
        "title",
        "model",
        "copilot_session_id",
        "created_at",
        "updated_at"
      ],
      "chat_messages" => [
        "id",
        "conversation_id",
        "role",
        "content",
        "tool_call_id",
        "tool_calls",
        "token_usage_input",
        "token_usage_output",
        "cache_read_tokens",
        "cache_write_tokens",
        "created_at"
      ],
      "ai_providers" => ["id", "name", "env", "package_ref", "api", "doc", "updated_at"],
      "ai_models" => [
        "provider",
        "model_id",
        "name",
        "family",
        "attachment",
        "reasoning",
        "tool_call",
        "structured_output",
        "temperature",
        "knowledge",
        "release_date",
        "last_updated_date",
        "open_weights",
        "input_price",
        "output_price",
        "cache_read_price",
        "cache_write_price",
        "context_window",
        "max_input_tokens",
        "max_output_tokens",
        "interleaved",
        "status",
        "provider_package_ref",
        "updated_at"
      ],
      "ai_model_modalities" => ["provider", "model_id", "direction", "modality"],
      "ai_catalog_meta" => ["key", "value"],
      "embedding_keys" => ["label", "post_id", "project_id", "content_hash", "vector"],
      "dismissed_duplicate_pairs" => [
        "id",
        "project_id",
        "post_id_a",
        "post_id_b",
        "dismissed_at"
      ],
      "import_definitions" => [
        "id",
        "project_id",
        "name",
        "wxr_file_path",
        "uploads_folder_path",
        "last_analysis_result",
        "created_at",
        "updated_at"
      ],
      "publish_jobs" => [
        "id",
        "project_id",
        "ssh_host",
        "ssh_user",
        "ssh_remote_path",
        "ssh_mode",
        "status",
        "task_id",
        "targets",
        "error",
        "inserted_at",
        "updated_at"
      ],
      "mcp_proposals" => [
        "id",
        "kind",
        "status",
        "entity_id",
        "data",
        "created_at",
        "expires_at"
      ],
      "db_notifications" => [
        "id",
        "entity_type",
        "entity_id",
        "action",
        "from_cli",
        "seen_at",
        "created_at"
      ]
    }

    actual_tables =
      query_rows("SELECT name FROM sqlite_master WHERE type = 'table'")
      |> Enum.map(&hd/1)
      |> MapSet.new()

    for {table, columns} <- expected_columns do
      assert MapSet.member?(actual_tables, table), "expected table #{table} to exist"
      assert MapSet.new(table_columns(table)) == MapSet.new(columns)
    end
  end

  test "creates the unique indexes and primary keys declared by the schema spec" do
    assert has_unique_index?("projects", ["slug"])
    assert unique_index_columns("posts", "posts_project_slug_idx") == ["project_id", "slug"]

    assert unique_index_columns(
             "post_translations",
             "post_translations_translation_language_idx"
           ) == ["translation_for", "language"]

    assert unique_index_columns(
             "media_translations",
             "media_translations_translation_language_idx"
           ) == ["translation_for", "language"]

    assert unique_index_columns("tags", "tags_project_name_idx") == ["project_id", "name"]
    assert unique_index_columns("scripts", "scripts_project_slug_idx") == ["project_id", "slug"]

    assert unique_index_columns("templates", "templates_project_slug_idx") == [
             "project_id",
             "slug"
           ]

    assert unique_index_columns("post_media", "post_media_post_media_idx") == [
             "post_id",
             "media_id"
           ]

    assert unique_index_columns(
             "generated_file_hashes",
             "generated_file_hashes_project_path_idx"
           ) == ["project_id", "relative_path"]

    assert unique_index_columns("mcp_proposals", "mcp_proposals_entity_idx") == [
             "kind",
             "entity_id",
             "status"
           ]

    assert unique_index_columns("dismissed_duplicate_pairs", "dismissed_pairs_idx") == [
             "project_id",
             "post_id_a",
             "post_id_b"
           ]

    assert primary_key_columns("ai_models") == ["provider", "model_id"]

    assert primary_key_columns("ai_model_modalities") == [
             "provider",
             "model_id",
             "direction",
             "modality"
           ]
  end

  test "creates standalone FTS5 virtual tables for post and media search" do
    posts_fts_sql = table_sql("posts_fts")
    media_fts_sql = table_sql("media_fts")

    assert posts_fts_sql =~ "CREATE VIRTUAL TABLE posts_fts USING fts5"
    assert posts_fts_sql =~ "post_id UNINDEXED"
    assert posts_fts_sql =~ "title"
    assert posts_fts_sql =~ "excerpt"
    assert posts_fts_sql =~ "content"
    assert posts_fts_sql =~ "tags"
    assert posts_fts_sql =~ "categories"
    refute posts_fts_sql =~ "content="

    assert media_fts_sql =~ "CREATE VIRTUAL TABLE media_fts USING fts5"
    assert media_fts_sql =~ "media_id UNINDEXED"
    assert media_fts_sql =~ "title"
    assert media_fts_sql =~ "alt"
    assert media_fts_sql =~ "caption"
    assert media_fts_sql =~ "original_name"
    assert media_fts_sql =~ "tags"
    refute media_fts_sql =~ "content="
  end

  test "applies key defaults and foreign keys from the persistence contract" do
    assert column_metadata("projects", "is_active")[:default] == "false"
    assert column_metadata("posts", "status")[:default] == "draft"
    assert column_metadata("posts", "file_path")[:default] == ""
    assert column_metadata("posts", "do_not_translate")[:default] == "false"
    assert column_metadata("post_media", "sort_order")[:default] == "0"
    assert column_metadata("publish_jobs", "status")[:default] == "pending"
    assert column_metadata("db_notifications", "from_cli")[:default] == "true"

    assert foreign_keys("posts") == [%{from: "project_id", table: "projects", to: "id"}]

    assert Enum.sort_by(foreign_keys("post_media"), & &1.from) == [
             %{from: "media_id", table: "media", to: "id"},
             %{from: "post_id", table: "posts", to: "id"},
             %{from: "project_id", table: "projects", to: "id"}
           ]

    assert Enum.sort_by(foreign_keys("post_translations"), & &1.from) == [
             %{from: "project_id", table: "projects", to: "id"},
             %{from: "translation_for", table: "posts", to: "id"}
           ]

    assert Enum.sort_by(foreign_keys("media_translations"), & &1.from) == [
             %{from: "project_id", table: "projects", to: "id"},
             %{from: "translation_for", table: "media", to: "id"}
           ]

    assert foreign_keys("publish_jobs") == [
             %{from: "project_id", table: "projects", to: "id"}
           ]

    assert foreign_keys("chat_messages") == [
             %{from: "conversation_id", table: "chat_conversations", to: "id"}
           ]

    assert foreign_keys("ai_models") == [%{from: "provider", table: "ai_providers", to: "id"}]
  end

  defp table_columns(table) do
    query_rows("PRAGMA table_info(#{table})")
    |> Enum.map(fn [_cid, name, _type, _notnull, _default, _pk] -> name end)
  end

  defp column_metadata(table, column_name) do
    query_rows("PRAGMA table_info(#{table})")
    |> Enum.find_value(fn [_cid, name, type, notnull, default, pk] ->
      if name == column_name do
        %{
          type: type,
          notnull: notnull,
          default: normalize_default(default),
          pk: pk
        }
      end
    end)
  end

  defp foreign_keys(table) do
    query_rows("PRAGMA foreign_key_list(#{table})")
    |> Enum.map(fn [_id, _seq, foreign_table, from, to, _on_update, _on_delete, _match] ->
      %{from: from, table: foreign_table, to: to}
    end)
  end

  defp primary_key_columns(table) do
    query_rows("PRAGMA table_info(#{table})")
    |> Enum.filter(fn [_cid, _name, _type, _notnull, _default, pk] -> pk > 0 end)
    |> Enum.sort_by(fn [_cid, _name, _type, _notnull, _default, pk] -> pk end)
    |> Enum.map(fn [_cid, name, _type, _notnull, _default, _pk] -> name end)
  end

  defp unique_index_columns(table, index_name) do
    indexes = query_rows("PRAGMA index_list(#{table})")

    assert Enum.any?(indexes, fn [_seq, name, unique | _rest] ->
             name == index_name and unique == 1
           end),
           "expected unique index #{index_name} on #{table}"

    query_rows("PRAGMA index_info(#{index_name})")
    |> Enum.sort_by(fn [seqno | _rest] -> seqno end)
    |> Enum.map(fn [_seqno, _cid, name] -> name end)
  end

  defp has_unique_index?(table, columns) do
    query_rows("PRAGMA index_list(#{table})")
    |> Enum.filter(fn [_seq, _name, unique | _rest] -> unique == 1 end)
    |> Enum.any?(fn [_seq, name, _unique | _rest] ->
      unique_index_columns(table, name) == columns
    end)
  end

  defp table_sql(table) do
    [[sql]] = query_rows("SELECT sql FROM sqlite_master WHERE name = '#{table}'")
    sql
  end

  defp query_rows(statement) do
    %{rows: rows} = SQL.query!(BDS.Repo, statement, [])
    rows
  end

  defp normalize_default(nil), do: nil

  defp normalize_default(default) do
    default
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end
end
