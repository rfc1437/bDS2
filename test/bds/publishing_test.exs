defmodule BDS.PublishingTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-publishing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Publishing", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "upload_site creates a publish job, uploads all targets, and excludes media sidecars", %{project: project, temp_dir: temp_dir} do
    test_pid = self()

    File.mkdir_p!(Path.join([temp_dir, "html"]))
    File.write!(Path.join([temp_dir, "html", "index.html"]), "<html />")

    File.mkdir_p!(Path.join([temp_dir, "thumbnails"]))
    File.write!(Path.join([temp_dir, "thumbnails", "thumb.jpg"]), "thumb")

    File.mkdir_p!(Path.join([temp_dir, "media"]))
    File.write!(Path.join([temp_dir, "media", "asset.jpg"]), "asset")
    File.write!(Path.join([temp_dir, "media", "asset.jpg.meta"]), "meta")

    uploader = fn target, files, credentials ->
      send(test_pid, {:uploaded, target.kind, target.remote_dir, Enum.sort(files), credentials.ssh_mode})
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

  test "upload_site marks the publish job failed when a target upload fails", %{project: project, temp_dir: temp_dir} do
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
end
