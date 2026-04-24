defmodule BDS.Repo.Migrations.AddBackendSpecCompliancePersistence do
  use Ecto.Migration

  def change do
    create table(:publish_jobs, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :ssh_host, :string, null: false
      add :ssh_user, :string, null: false
      add :ssh_remote_path, :string, null: false
      add :ssh_mode, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :task_id, :string
      add :targets, {:array, :string}, null: false, default: []
      add :error, :text
      add :inserted_at, :integer, null: false
      add :updated_at, :integer, null: false
    end

    create table(:mcp_proposals, primary_key: false) do
      add :id, :string, primary_key: true
      add :kind, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :entity_id, :string, null: false
      add :data, :map, null: false
      add :created_at, :integer, null: false
      add :expires_at, :integer, null: false
    end

    create unique_index(:mcp_proposals, [:kind, :entity_id, :status],
             name: :mcp_proposals_entity_idx
           )
  end
end
