defmodule BDS.Repo.Migrations.AddAiChatUsageFields do
  use Ecto.Migration

  def change do
    alter table(:chat_messages) do
      add :token_usage_input, :integer
      add :token_usage_output, :integer
      add :cache_read_tokens, :integer
      add :cache_write_tokens, :integer
    end
  end
end
