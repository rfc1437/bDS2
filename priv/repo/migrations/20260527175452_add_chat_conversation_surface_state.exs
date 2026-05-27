defmodule BDS.Repo.Migrations.AddChatConversationSurfaceState do
  use Ecto.Migration

  def change do
    alter table(:chat_conversations) do
      add :surface_state, :text
    end
  end
end
