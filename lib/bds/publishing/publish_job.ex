defmodule BDS.Publishing.PublishJob do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "publish_jobs" do
    field :project_id, :string
    field :ssh_host, :string
    field :ssh_user, :string
    field :ssh_remote_path, :string
    field :ssh_mode, Ecto.Enum, values: [:scp, :rsync], default: :scp
    field :status, Ecto.Enum, values: [:pending, :running, :completed, :failed], default: :pending
    field :task_id, :string
    field :targets, {:array, :string}, default: []
    field :error, :string
    field :inserted_at, :integer
    field :updated_at, :integer
  end

  def changeset(job, attrs) do
    job
    |> cast(
      attrs,
      [
        :id,
        :project_id,
        :ssh_host,
        :ssh_user,
        :ssh_remote_path,
        :ssh_mode,
        :status,
        :task_id,
        :targets,
        :error,
        :inserted_at,
        :updated_at
      ],
      empty_values: [nil]
    )
    |> validate_required([
      :id,
      :project_id,
      :ssh_host,
      :ssh_user,
      :ssh_remote_path,
      :ssh_mode,
      :status,
      :targets,
      :inserted_at,
      :updated_at
    ])
    |> foreign_key_constraint(:project_id)
  end
end
