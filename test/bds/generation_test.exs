defmodule BDS.GenerationTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-generation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Generation", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "write_generated_file writes under html output and skips unchanged content by hash", %{project: project, temp_dir: temp_dir} do
    assert {:ok, first_write} = BDS.Generation.write_generated_file(project.id, "index.html", "<html>hello</html>")
    assert first_write.written? == true

    output_path = Path.join([temp_dir, "html", "index.html"])
    assert File.read!(output_path) == "<html>hello</html>"

    assert {:ok, [tracked_file]} = BDS.Generation.list_generated_files(project.id)
    assert tracked_file.relative_path == "index.html"
    assert tracked_file.content_hash == first_write.content_hash

    assert {:ok, second_write} = BDS.Generation.write_generated_file(project.id, "index.html", "<html>hello</html>")
    assert second_write.written? == false
    assert second_write.content_hash == first_write.content_hash

    assert {:ok, third_write} = BDS.Generation.write_generated_file(project.id, "index.html", "<html>updated</html>")
    assert third_write.written? == true
    assert third_write.content_hash != first_write.content_hash
    assert File.read!(output_path) == "<html>updated</html>"
  end

  test "delete_generated_file removes tracked output and forgets its hash", %{project: project, temp_dir: temp_dir} do
    assert {:ok, _write} = BDS.Generation.write_generated_file(project.id, "tag/elixir/index.html", "<html>tag</html>")

    output_path = Path.join([temp_dir, "html", "tag", "elixir", "index.html"])
    assert File.exists?(output_path)

    assert :ok = BDS.Generation.delete_generated_file(project.id, "tag/elixir/index.html")
    refute File.exists?(output_path)

    assert {:ok, files} = BDS.Generation.list_generated_files(project.id)
    assert files == []
  end
end
