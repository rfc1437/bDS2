defmodule BDS.Repo.Migrations.AddMissingIndexes do
  use Ecto.Migration

  def change do
    # Foreign key indexes
    create index(:media, [:project_id])
    create index(:post_media, [:post_id])
    create index(:post_media, [:media_id])
    create index(:chat_messages, [:conversation_id])
    create index(:embedding_keys, [:post_id])
    create index(:embedding_keys, [:project_id])
    create index(:dismissed_duplicate_pairs, [:project_id])
    create index(:import_definitions, [:project_id])
    create index(:publish_jobs, [:project_id])

    # Frequently filtered columns
    create index(:posts, [:status])
    create index(:posts, [:published_at])
    create index(:posts, [:language])

    # db_notifications lookup columns
    create index(:db_notifications, [:entity_type, :entity_id])
  end
end
