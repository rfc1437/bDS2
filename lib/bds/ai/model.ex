defmodule BDS.AI.Model do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "ai_models" do
    field :provider, :string, primary_key: true
    field :model_id, :string, primary_key: true
    field :name, :string
    field :family, :string
    field :supports_attachment, :boolean, source: :attachment, default: false
    field :supports_reasoning, :boolean, source: :reasoning, default: false
    field :supports_tool_calls, :boolean, source: :tool_call, default: false
    field :supports_structured_output, :boolean, source: :structured_output, default: false
    field :supports_temperature, :boolean, source: :temperature, default: false
    field :knowledge, :string
    field :release_date, :string
    field :last_updated_date, :string
    field :open_weights, :boolean, default: false
    field :input_price, :integer
    field :output_price, :integer
    field :cache_read_price, :integer
    field :cache_write_price, :integer
    field :context_window, :integer
    field :max_input_tokens, :integer
    field :max_output_tokens, :integer
    field :interleaved, :string
    field :status, :string
    field :updated_at, :integer
  end

  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :provider,
      :model_id,
      :name,
      :family,
      :supports_attachment,
      :supports_reasoning,
      :supports_tool_calls,
      :supports_structured_output,
      :supports_temperature,
      :knowledge,
      :release_date,
      :last_updated_date,
      :open_weights,
      :input_price,
      :output_price,
      :cache_read_price,
      :cache_write_price,
      :context_window,
      :max_input_tokens,
      :max_output_tokens,
      :interleaved,
      :status,
      :updated_at
    ], empty_values: [nil])
    |> validate_required([:provider, :model_id, :name, :context_window, :max_input_tokens, :max_output_tokens, :updated_at])
  end
end
