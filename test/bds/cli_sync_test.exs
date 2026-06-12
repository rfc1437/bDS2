defmodule BDS.CliSyncTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.CliSync
  alias BDS.CliSync.Watcher
  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Repo.delete_all(BDS.CliSync.Notification)
    :ok
  end

  test "app-side writes do not produce notification rows (AppNoopNotifier)", %{} do
    existing_before_create = Repo.aggregate(BDS.CliSync.Notification, :count)

    # Perform a few app-side operations — post create, media import, metadata
    # update — none should leave a notification row behind.
    temp_dir =
      Path.join(System.tmp_dir!(), "bds-app-noop-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "AppNoop", data_path: temp_dir})

    {:ok, _post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "App-Created",
        content: "body"
      })

    source_path = Path.join(temp_dir, "image.png")
    File.write!(source_path, "fake png")
    {:ok, _media} = BDS.Media.import_media(%{project_id: project.id, source_path: source_path})

    {:ok, _metadata} =
      BDS.Metadata.update_project_metadata(project.id, %{name: "Renamed"})

    existing_after = Repo.aggregate(BDS.CliSync.Notification, :count)
    assert existing_after == existing_before_create
  end

  test "cli mutations are written to db_notifications, processed on file change, and marked seen" do
    assert {:ok, notification} = CliSync.cli_mutation_performed("post", "post-1", :updated)
    assert notification.from_cli == true
    assert notification.seen_at == nil

    assert {:ok, processed} = CliSync.db_file_change_detected()
    assert [%{entity_type: "post", entity_id: "post-1", action: :updated}] = processed

    seen_notification = Repo.get!(BDS.CliSync.Notification, notification.id)
    assert is_integer(seen_notification.seen_at)
  end

  test "watcher broadcasts entity change events after database mutations are detected" do
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})
    Phoenix.PubSub.subscribe(BDS.PubSub, Watcher.topic())

    watcher =
      start_supervised!({Watcher, poll_interval_ms: 60_000, debounce_ms: 0})

    Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), watcher)

    assert {:ok, notification} = CliSync.cli_mutation_performed("post", "post-1", :updated)

    :ok = Watcher.poll_now(watcher)

    assert_receive {:entity_changed, %{entity: "post", entity_id: "post-1", action: :updated}},
                   500

    seen_notification = Repo.get!(BDS.CliSync.Notification, notification.id)
    assert is_integer(seen_notification.seen_at)
  end

  test "watcher skips notification queries when sqlite data_version is unchanged" do
    test_pid = self()
    data_version = :erlang.make_ref()
    :persistent_term.put(data_version, [7, 7])

    data_version_reader = fn ->
      [next | rest] = :persistent_term.get(data_version)
      :persistent_term.put(data_version, rest)
      next
    end

    notification_fetcher = fn ->
      send(test_pid, :notifications_fetched)
      {:ok, []}
    end

    pruner = fn ->
      send(test_pid, :notifications_pruned)
      {:ok, %{processed: 0, unprocessed: 0}}
    end

    on_exit(fn -> :persistent_term.erase(data_version) end)

    watcher =
      start_supervised!(
        {Watcher,
         poll_interval_ms: 60_000,
         data_version_reader: data_version_reader,
         notification_fetcher: notification_fetcher,
         pruner: pruner}
      )

    :ok = Watcher.poll_now(watcher)
    assert_receive :notifications_fetched, 500
    assert_receive :notifications_pruned, 500

    :ok = Watcher.poll_now(watcher)
    refute_receive :notifications_fetched, 100
    refute_receive :notifications_pruned, 100
  end

  test "processed notifications are pruned after one hour and unprocessed notifications after one day" do
    now = BDS.Persistence.now_ms()

    Repo.insert!(%BDS.CliSync.Notification{
      entity_type: "post",
      entity_id: "processed-old",
      action: :updated,
      from_cli: true,
      seen_at: now - 10,
      created_at: now - 3_600_001
    })

    Repo.insert!(%BDS.CliSync.Notification{
      entity_type: "media",
      entity_id: "unprocessed-old",
      action: :deleted,
      from_cli: true,
      seen_at: nil,
      created_at: now - 86_400_001
    })

    Repo.insert!(%BDS.CliSync.Notification{
      entity_type: "script",
      entity_id: "fresh",
      action: :created,
      from_cli: true,
      seen_at: nil,
      created_at: now
    })

    assert {:ok, %{processed: 1, unprocessed: 1}} = CliSync.prune_notifications(now)

    remaining_ids =
      Repo.all(from notification in BDS.CliSync.Notification, select: notification.entity_id)

    assert remaining_ids == ["fresh"]
  end
end
