defmodule BDS.Repo.Migrations.CreatePersistenceContract do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :data_path, :string
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
      add :is_active, :boolean, null: false, default: false
    end

    create unique_index(:projects, [:slug])

    create table(:posts, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :slug, :string, null: false
      add :excerpt, :text
      add :content, :text
      add :status, :string, null: false, default: "draft"
      add :author, :string
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
      add :published_at, :integer
      add :file_path, :string, null: false, default: ""
      add :checksum, :string
      add :tags, :text
      add :categories, :text
      add :template_slug, :string
      add :language, :string
      add :do_not_translate, :boolean, null: false, default: false
      add :published_title, :text
      add :published_content, :text
      add :published_tags, :text
      add :published_categories, :text
      add :published_excerpt, :text
    end

    create unique_index(:posts, [:project_id, :slug], name: :posts_project_slug_idx)

    create table(:post_translations, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false

      add :translation_for, references(:posts, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :language, :string, null: false
      add :title, :string, null: false
      add :excerpt, :text
      add :content, :text
      add :status, :string, null: false, default: "draft"
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
      add :published_at, :integer
      add :file_path, :string, null: false, default: ""
      add :checksum, :string
    end

    create unique_index(:post_translations, [:translation_for, :language],
             name: :post_translations_translation_language_idx
           )

    create table(:media, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :original_name, :string, null: false
      add :mime_type, :string, null: false
      add :size, :integer, null: false
      add :width, :integer
      add :height, :integer
      add :title, :string
      add :alt, :text
      add :caption, :text
      add :author, :string
      add :file_path, :string, null: false
      add :sidecar_path, :string, null: false
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
      add :checksum, :string
      add :tags, :text
      add :language, :string
    end

    create table(:media_translations, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false

      add :translation_for, references(:media, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :language, :string, null: false
      add :title, :string
      add :alt, :text
      add :caption, :text
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
    end

    create unique_index(:media_translations, [:translation_for, :language],
             name: :media_translations_translation_language_idx
           )

    create table(:tags, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color, :string
      add :post_template_slug, :string
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
    end

    create unique_index(:tags, [:project_id, :name], name: :tags_project_name_idx)

    create table(:templates, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :slug, :string, null: false
      add :title, :string, null: false
      add :kind, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :version, :integer, null: false, default: 1
      add :file_path, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :content, :text
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
    end

    create unique_index(:templates, [:project_id, :slug], name: :templates_project_slug_idx)

    create table(:scripts, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :slug, :string, null: false
      add :title, :string, null: false
      add :kind, :string, null: false
      add :entrypoint, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :version, :integer, null: false, default: 1
      add :file_path, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :content, :text
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
    end

    create unique_index(:scripts, [:project_id, :slug], name: :scripts_project_slug_idx)

    create table(:post_links, primary_key: false) do
      add :id, :string, primary_key: true

      add :source_post_id, references(:posts, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :target_post_id, references(:posts, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :link_text, :text
      add :created_at, :integer, null: false
    end

    create table(:post_media, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :post_id, references(:posts, column: :id, type: :string, on_delete: :delete_all), null: false
      add :media_id, references(:media, column: :id, type: :string, on_delete: :delete_all), null: false
      add :sort_order, :integer, null: false, default: 0
      add :created_at, :integer, null: false
    end

    create unique_index(:post_media, [:post_id, :media_id], name: :post_media_post_media_idx)

    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text, null: false
      add :updated_at, :integer, null: false
    end

    create table(:generated_file_hashes, primary_key: false) do
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :relative_path, :string, null: false
      add :content_hash, :string, null: false
      add :updated_at, :integer, null: false
    end

    create unique_index(:generated_file_hashes, [:project_id, :relative_path],
             name: :generated_file_hashes_project_path_idx
           )

    create table(:chat_conversations, primary_key: false) do
      add :id, :string, primary_key: true
      add :title, :string, null: false
      add :model, :string
      add :copilot_session_id, :string
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
    end

    create table(:chat_messages) do
      add :conversation_id,
          references(:chat_conversations, column: :id, type: :string, on_delete: :delete_all),
          null: false

      add :role, :string, null: false
      add :content, :text
      add :tool_call_id, :string
      add :tool_calls, :text
      add :created_at, :integer, null: false
    end

    create table(:ai_providers, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :env, :string
      add :package_ref, :string
      add :api, :string
      add :doc, :string
      add :updated_at, :integer, null: false
    end

    create table(:ai_models, primary_key: false) do
      add :provider, references(:ai_providers, type: :string, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :model_id, :string, primary_key: true
      add :name, :string, null: false
      add :family, :string
      add :attachment, :boolean, null: false, default: false
      add :reasoning, :boolean, null: false, default: false
      add :tool_call, :boolean, null: false, default: false
      add :structured_output, :boolean, null: false, default: false
      add :temperature, :boolean, null: false, default: false
      add :knowledge, :string
      add :release_date, :string
      add :last_updated_date, :string
      add :open_weights, :boolean, null: false, default: false
      add :input_price, :integer
      add :output_price, :integer
      add :cache_read_price, :integer
      add :cache_write_price, :integer
      add :context_window, :integer, null: false
      add :max_input_tokens, :integer, null: false
      add :max_output_tokens, :integer, null: false
      add :interleaved, :string
      add :status, :string
      add :provider_package_ref, :string
      add :updated_at, :integer, null: false
    end

    create table(:ai_model_modalities, primary_key: false) do
      add :provider, references(:ai_providers, type: :string, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :model_id, :string, primary_key: true
      add :direction, :string, primary_key: true
      add :modality, :string, primary_key: true
    end

    create table(:ai_catalog_meta, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string, null: false
    end

    create table(:embedding_keys, primary_key: false) do
      add :label, :integer, primary_key: true
      add :post_id, references(:posts, column: :id, type: :string, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :content_hash, :string, null: false
      add :vector, :text
    end

    create table(:dismissed_duplicate_pairs, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false

      add :post_id_a, references(:posts, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :post_id_b, references(:posts, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :dismissed_at, :integer, null: false
    end

    create unique_index(:dismissed_duplicate_pairs, [:project_id, :post_id_a, :post_id_b],
             name: :dismissed_pairs_idx
           )

    create table(:import_definitions, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :wxr_file_path, :string
      add :uploads_folder_path, :string
      add :last_analysis_result, :text
      add :created_at, :integer, null: false
      add :updated_at, :integer, null: false
    end

    create table(:db_notifications) do
      add :entity_type, :string, null: false
      add :entity_id, :string, null: false
      add :action, :string, null: false
      add :from_cli, :boolean, null: false, default: true
      add :seen_at, :integer
      add :created_at, :integer, null: false
    end

    execute(
      """
      CREATE VIRTUAL TABLE posts_fts USING fts5(
        post_id UNINDEXED,
        title,
        excerpt,
        content,
        tags,
        categories
      )
      """,
      "DROP TABLE IF EXISTS posts_fts"
    )

    execute(
      """
      CREATE VIRTUAL TABLE media_fts USING fts5(
        media_id UNINDEXED,
        title,
        alt,
        caption,
        original_name,
        tags
      )
      """,
      "DROP TABLE IF EXISTS media_fts"
    )
  end
end
