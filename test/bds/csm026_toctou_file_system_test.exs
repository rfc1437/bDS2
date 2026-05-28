defmodule BDS.TOCTOU.FileSystemTest do
  use ExUnit.Case, async: true

  alias BDS.Rendering.FileSystem, as: TemplateFileSystem

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "bds-toctou-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "try_read/2 eliminates TOCTOU race" do
    test "reads file atomically without separate existence check", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "header.liquid"), "HEADER CONTENT")
      fs = TemplateFileSystem.new(tmp_dir)

      assert {:ok, "HEADER CONTENT"} = TemplateFileSystem.try_read(fs, "header")
    end

    test "returns {:error, :enoent} for missing templates", %{tmp_dir: tmp_dir} do
      fs = TemplateFileSystem.new(tmp_dir)

      assert {:error, :enoent} = TemplateFileSystem.try_read(fs, "nonexistent")
    end

    test "falls through to next root path when first is missing", %{tmp_dir: tmp_dir} do
      root_a = Path.join(tmp_dir, "a")
      root_b = Path.join(tmp_dir, "b")
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)
      File.write!(Path.join(root_b, "partial.liquid"), "FROM B")

      fs = TemplateFileSystem.new([root_a, root_b])

      assert {:ok, "FROM B"} = TemplateFileSystem.try_read(fs, "partial")
    end

    test "first root path wins when both have the template", %{tmp_dir: tmp_dir} do
      root_a = Path.join(tmp_dir, "a")
      root_b = Path.join(tmp_dir, "b")
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)
      File.write!(Path.join(root_a, "shared.liquid"), "FROM A")
      File.write!(Path.join(root_b, "shared.liquid"), "FROM B")

      fs = TemplateFileSystem.new([root_a, root_b])

      assert {:ok, "FROM A"} = TemplateFileSystem.try_read(fs, "shared")
    end

    test "file deleted between candidate_paths and try_read does not crash", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ephemeral.liquid")
      File.write!(path, "TEMPORARY")
      fs = TemplateFileSystem.new(tmp_dir)

      _candidates = TemplateFileSystem.candidate_paths(fs, "ephemeral")
      File.rm!(path)

      assert {:error, :enoent} = TemplateFileSystem.try_read(fs, "ephemeral")
    end
  end

  describe "read_template_file/2 protocol uses atomic read" do
    test "reads existing template", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "footer.liquid"), "FOOTER")
      fs = TemplateFileSystem.new(tmp_dir)

      assert "FOOTER" = Liquex.FileSystem.read_template_file(fs, "footer")
    end

    test "raises on missing template", %{tmp_dir: tmp_dir} do
      fs = TemplateFileSystem.new(tmp_dir)

      assert_raise Liquex.Error, ~r/No such template/, fn ->
        Liquex.FileSystem.read_template_file(fs, "missing")
      end
    end
  end

  describe "candidate_paths/2 validation" do
    test "raises on empty path" do
      fs = TemplateFileSystem.new("/tmp")

      assert_raise Liquex.Error, ~r/Illegal template path/, fn ->
        TemplateFileSystem.candidate_paths(fs, "")
      end
    end

    test "raises on absolute path" do
      fs = TemplateFileSystem.new("/tmp")

      assert_raise Liquex.Error, ~r/Illegal template path/, fn ->
        TemplateFileSystem.candidate_paths(fs, "/etc/passwd")
      end
    end

    test "raises on path traversal" do
      fs = TemplateFileSystem.new("/tmp")

      assert_raise Liquex.Error, ~r/Illegal template path/, fn ->
        TemplateFileSystem.candidate_paths(fs, "../secret")
      end
    end
  end
end
