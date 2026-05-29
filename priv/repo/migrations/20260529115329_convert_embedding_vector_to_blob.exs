defmodule BDS.Repo.Migrations.ConvertEmbeddingVectorToBlob do
  use Ecto.Migration

  # Embedding vectors are now persisted as a packed little-endian Float32 BLOB
  # (VectorCacheInDb invariant) instead of JSON text. The table is a rebuildable
  # cache and the previous lexical vectors are incompatible with the neural
  # model, so we drop and recreate it; rows are re-embedded on next index.

  def up do
    drop table(:embedding_keys)
    create_embedding_keys(:binary)
  end

  def down do
    drop table(:embedding_keys)
    create_embedding_keys(:text)
  end

  defp create_embedding_keys(vector_type) do
    create table(:embedding_keys, primary_key: false) do
      add :label, :integer, primary_key: true
      add :post_id, references(:posts, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :content_hash, :string, null: false
      add :vector, vector_type
    end

    create index(:embedding_keys, [:post_id])
    create index(:embedding_keys, [:project_id])
  end
end
