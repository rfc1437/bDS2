defmodule BDS.AlignmentTest do
  use ExUnit.Case, async: true

  @media_import_specs [
    "specs/media.allium",
    "specs/media_processing.allium"
  ]

  test "media import specs use one source-path-first event shape" do
    signatures =
      @media_import_specs
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> import_media_signatures(path)
      end)

    assert signatures == [
             {"specs/media.allium", "source_path, project, metadata"},
             {"specs/media.allium", "source_path, project, metadata"},
             {"specs/media_processing.allium", "source_path, project, metadata"},
             {"specs/media_processing.allium", "source_path, project, metadata"}
           ]
  end

  defp import_media_signatures(source, path) do
    ~r/ImportMediaRequested\(([^)]+)\)/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [signature] -> {path, signature} end)
  end
end
