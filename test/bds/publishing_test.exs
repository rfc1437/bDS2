defmodule BDS.PublishingTest do
  use ExUnit.Case, async: false

  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), Process.whereis(BDS.Publishing))

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-publishing-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Publishing", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "upload_site creates a publish job, uploads all targets, and excludes media sidecars", %{
    project: project,
    temp_dir: temp_dir
  } do
    test_pid = self()

    File.mkdir_p!(Path.join([temp_dir, "html"]))
    File.write!(Path.join([temp_dir, "html", "index.html"]), "<html />")

    File.mkdir_p!(Path.join([temp_dir, "thumbnails"]))
    File.write!(Path.join([temp_dir, "thumbnails", "thumb.jpg"]), "thumb")

    File.mkdir_p!(Path.join([temp_dir, "media"]))
    File.write!(Path.join([temp_dir, "media", "asset.jpg"]), "asset")
    File.write!(Path.join([temp_dir, "media", "asset.jpg.meta"]), "meta")

    uploader = fn target, files, credentials ->
      send(
        test_pid,
        {:uploaded, target.kind, target.remote_dir, Enum.sort(files), credentials.ssh_mode}
      )

      :ok
    end

    credentials = %{
      ssh_host: "example.com",
      ssh_user: "deploy",
      ssh_remote_path: "/srv/blog",
      ssh_mode: :rsync
    }

    assert {:ok, job} = BDS.Publishing.upload_site(project.id, credentials, uploader: uploader)
    assert job.status in [:pending, :running]

    assert wait_for_publish_job(job.id, &(&1.status == :completed)).status == :completed

    assert_receive {:uploaded, :html, "/srv/blog", ["index.html"], :rsync}
    assert_receive {:uploaded, :thumbnails, "/srv/blog/thumbnails", ["thumb.jpg"], :rsync}
    assert_receive {:uploaded, :media, "/srv/blog/media", ["asset.jpg"], :rsync}
  end

  test "upload_site runs rsync commands with SSH agent env and media exclude filters", %{
    project: project,
    temp_dir: temp_dir
  } do
    test_pid = self()

    File.mkdir_p!(Path.join([temp_dir, "html"]))
    File.write!(Path.join([temp_dir, "html", "index.html"]), "<html />")
    File.mkdir_p!(Path.join([temp_dir, "thumbnails"]))
    File.write!(Path.join([temp_dir, "thumbnails", "thumb.jpg"]), "thumb")
    File.mkdir_p!(Path.join([temp_dir, "media"]))
    File.write!(Path.join([temp_dir, "media", "asset.jpg"]), "asset")
    File.write!(Path.join([temp_dir, "media", "asset.jpg.meta"]), "meta")

    runner = fn command, args, opts ->
      send(test_pid, {:command_run, command, args, opts})
      {"", 0}
    end

    credentials = %{
      ssh_host: "example.com",
      ssh_user: "deploy",
      ssh_remote_path: "/srv/blog",
      ssh_mode: :rsync
    }

    assert {:ok, job} =
             BDS.Publishing.upload_site(project.id, credentials,
               command_runner: runner,
               ssh_auth_sock: "/tmp/test-agent.sock"
             )

    assert wait_for_publish_job(job.id, &(&1.status == :completed)).status == :completed

    assert_receive {:command_run, "rsync", html_args, html_opts}

    assert html_args == [
             "--update",
             "--compress",
             "--verbose",
             "-e",
             "ssh",
             Path.join([temp_dir, "html"]) <> "/",
             "deploy@example.com:/srv/blog/"
           ]

    assert html_opts[:env] == [{"SSH_AUTH_SOCK", "/tmp/test-agent.sock"}]

    assert_receive {:command_run, "rsync", thumb_args, _thumb_opts}

    assert thumb_args == [
             "--update",
             "--compress",
             "--verbose",
             "-e",
             "ssh",
             Path.join([temp_dir, "thumbnails"]) <> "/",
             "deploy@example.com:/srv/blog/thumbnails/"
           ]

    assert_receive {:command_run, "rsync", media_args, _media_opts}

    assert media_args == [
             "--update",
             "--compress",
             "--verbose",
             "--exclude=*.meta",
             "-e",
             "ssh",
             Path.join([temp_dir, "media"]) <> "/",
             "deploy@example.com:/srv/blog/media/"
           ]
  end

  test "upload_site runs scp commands for each eligible file and fails when a command exits non-zero",
       %{project: project, temp_dir: temp_dir} do
    test_pid = self()
    html_index = Path.join([temp_dir, "html", "index.html"])
    html_entry = Path.join([temp_dir, "html", "posts", "entry.html"])
    thumb_path = Path.join([temp_dir, "thumbnails", "thumb.jpg"])

    File.mkdir_p!(Path.join([temp_dir, "html", "posts"]))
    File.write!(html_index, "<html />")
    File.write!(html_entry, "<html />")
    File.mkdir_p!(Path.join([temp_dir, "thumbnails"]))
    File.write!(thumb_path, "thumb")
    File.mkdir_p!(Path.join([temp_dir, "media"]))
    File.write!(Path.join([temp_dir, "media", "asset.jpg"]), "asset")
    File.write!(Path.join([temp_dir, "media", "asset.jpg.meta"]), "meta")

    runner = fn command, args, opts ->
      send(test_pid, {:command_run, command, args, opts})

      if List.last(args) == "deploy@example.com:/srv/blog/thumbnails/thumb.jpg" do
        {"thumbnail failure", 1}
      else
        {"", 0}
      end
    end

    credentials = %{
      ssh_host: "example.com",
      ssh_user: "deploy",
      ssh_remote_path: "/srv/blog",
      ssh_mode: :scp
    }

    assert {:ok, job} =
             BDS.Publishing.upload_site(project.id, credentials,
               command_runner: runner,
               ssh_auth_sock: "/tmp/test-agent.sock"
             )

    failed_job = wait_for_publish_job(job.id, &(&1.status == :failed))
    assert failed_job.error =~ "thumbnail failure"

    assert_receive {:command_run, "scp",
                    ["-q", ^html_index, "deploy@example.com:/srv/blog/index.html"], opts_a}

    assert opts_a[:env] == [{"SSH_AUTH_SOCK", "/tmp/test-agent.sock"}]

    assert_receive {:command_run, "scp",
                    ["-q", ^html_entry, "deploy@example.com:/srv/blog/posts/entry.html"], _opts_b}

    assert_receive {:command_run, "scp",
                    ["-q", ^thumb_path, "deploy@example.com:/srv/blog/thumbnails/thumb.jpg"],
                    _opts_c}

    refute_receive {:command_run, "scp",
                    ["-q", _, "deploy@example.com:/srv/blog/media/asset.jpg"], _opts_d}
  end

  test "upload_site marks the publish job failed when a target upload fails", %{
    project: project,
    temp_dir: temp_dir
  } do
    File.mkdir_p!(Path.join([temp_dir, "html"]))
    File.write!(Path.join([temp_dir, "html", "index.html"]), "<html />")
    File.mkdir_p!(Path.join([temp_dir, "thumbnails"]))
    File.write!(Path.join([temp_dir, "thumbnails", "thumb.jpg"]), "thumb")
    File.mkdir_p!(Path.join([temp_dir, "media"]))
    File.write!(Path.join([temp_dir, "media", "asset.jpg"]), "asset")

    uploader = fn target, _files, _credentials ->
      if target.kind == :thumbnails, do: {:error, "thumbnail failure"}, else: :ok
    end

    credentials = %{
      ssh_host: "example.com",
      ssh_user: "deploy",
      ssh_remote_path: "/srv/blog",
      ssh_mode: :scp
    }

    assert {:ok, job} = BDS.Publishing.upload_site(project.id, credentials, uploader: uploader)

    failed_job = wait_for_publish_job(job.id, &(&1.status == :failed))
    assert failed_job.error == "thumbnail failure"
  end

  test "upload_site skips unchanged files for scp and only re-uploads files with newer mtimes", %{
    project: project,
    temp_dir: temp_dir
  } do
    test_pid = self()
    html_index = Path.join([temp_dir, "html", "index.html"])
    media_asset = Path.join([temp_dir, "media", "asset.jpg"])

    File.mkdir_p!(Path.dirname(html_index))
    File.write!(html_index, "<html />")
    File.mkdir_p!(Path.join([temp_dir, "thumbnails"]))
    File.write!(Path.join([temp_dir, "thumbnails", "thumb.jpg"]), "thumb")
    File.mkdir_p!(Path.dirname(media_asset))
    File.write!(media_asset, "asset")

    runner = fn command, args, opts ->
      send(test_pid, {:command_run, command, args, opts})
      {"", 0}
    end

    credentials = %{
      ssh_host: "example.com",
      ssh_user: "deploy",
      ssh_remote_path: "/srv/blog",
      ssh_mode: :scp
    }

    assert {:ok, first_job} =
             BDS.Publishing.upload_site(project.id, credentials,
               command_runner: runner,
               ssh_auth_sock: "/tmp/test-agent.sock"
             )

    assert wait_for_publish_job(first_job.id, &(&1.status == :completed)).status == :completed
    first_uploads = collect_command_runs()
    assert length(first_uploads) == 3

    assert {:ok, second_job} =
             BDS.Publishing.upload_site(project.id, credentials,
               command_runner: runner,
               ssh_auth_sock: "/tmp/test-agent.sock"
             )

    assert wait_for_publish_job(second_job.id, &(&1.status == :completed)).status == :completed
    assert collect_command_runs() == []

    :ok = File.touch(html_index, {{2099, 1, 1}, {0, 0, 0}})

    assert {:ok, third_job} =
             BDS.Publishing.upload_site(project.id, credentials,
               command_runner: runner,
               ssh_auth_sock: "/tmp/test-agent.sock"
             )

    assert wait_for_publish_job(third_job.id, &(&1.status == :completed)).status == :completed

    assert [html_upload] = collect_command_runs()
    assert elem(html_upload, 0) == "scp"
    assert elem(html_upload, 1) == ["-q", html_index, "deploy@example.com:/srv/blog/index.html"]
  end

  test "publish jobs survive a publishing server restart because they are persisted", %{
    project: project,
    temp_dir: temp_dir
  } do
    File.mkdir_p!(Path.join([temp_dir, "html"]))
    File.write!(Path.join([temp_dir, "html", "index.html"]), "<html />")

    credentials = %{
      ssh_host: "example.com",
      ssh_user: "deploy",
      ssh_remote_path: "/srv/blog",
      ssh_mode: :rsync
    }

    assert {:ok, job} =
             BDS.Publishing.upload_site(project.id, credentials, uploader: fn _, _, _ -> :ok end)

    assert wait_for_publish_job(job.id, &(&1.status == :completed)).status == :completed

    persisted_before_restart = Repo.get!(BDS.Publishing.PublishJob, job.id)
    assert persisted_before_restart.status == :completed

    publishing_pid = Process.whereis(BDS.Publishing)
    ref = Process.monitor(publishing_pid)
    :ok = GenServer.stop(BDS.Publishing, :normal)
    assert_receive {:DOWN, ^ref, :process, ^publishing_pid, _reason}

    restarted_pid = wait_for_process(BDS.Publishing)
    refute restarted_pid == publishing_pid

    :ok = Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), restarted_pid)

    persisted_after_restart = BDS.Publishing.get_job(job.id)
    assert persisted_after_restart.id == job.id
    assert persisted_after_restart.status == :completed
  end

  defp collect_command_runs(acc \\ []) do
    receive do
      {:command_run, command, args, _opts} -> collect_command_runs([{command, args} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp wait_for_publish_job(job_id, predicate, attempts \\ 100)

  defp wait_for_publish_job(job_id, predicate, attempts) when attempts > 0 do
    job = BDS.Publishing.get_job(job_id)

    if predicate.(job) do
      job
    else
      Process.sleep(20)
      wait_for_publish_job(job_id, predicate, attempts - 1)
    end
  end

  defp wait_for_publish_job(_job_id, _predicate, 0) do
    flunk("publish job did not reach expected state")
  end

  defp wait_for_process(name, attempts \\ 100)

  defp wait_for_process(name, attempts) when attempts > 0 do
    case Process.whereis(name) do
      nil ->
        Process.sleep(20)
        wait_for_process(name, attempts - 1)

      pid ->
        pid
    end
  end

  defp wait_for_process(name, 0) do
    flunk("process #{inspect(name)} did not restart")
  end
end
