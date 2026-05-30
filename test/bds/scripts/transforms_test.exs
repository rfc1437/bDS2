defmodule BDS.Scripts.TransformsTest do
  use ExUnit.Case, async: false

  alias BDS.Scripts
  alias BDS.Scripts.Transforms

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-transforms-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Transforms", data_path: temp_dir})

    %{project: project}
  end

  defp transform(project_id, title, content, opts \\ []) do
    {:ok, script} =
      Scripts.create_script(%{
        project_id: project_id,
        title: title,
        kind: :transform,
        content: content,
        entrypoint: Keyword.get(opts, :entrypoint, "main")
      })

    script =
      case Keyword.get(opts, :enabled, true) do
        true ->
          script

        false ->
          {:ok, s} = Scripts.update_script(script.id, %{enabled: false})
          s
      end

    script
  end

  test "runs enabled transforms in deterministic order (updated_at, slug, id)", %{
    project: project
  } do
    # Each transform appends its marker to content so we can read execution order.
    transform(project.id, "Bravo", """
    function main(data, _ctx)
      data.content = data.content .. "B"
      return data
    end
    """)

    # Ensure distinct updated_at ordering by spacing out creation.
    Process.sleep(5)

    transform(project.id, "Alpha", """
    function main(data, _ctx)
      data.content = data.content .. "A"
      return data
    end
    """)

    data = %{
      "title" => "t",
      "content" => "",
      "tags" => [],
      "categories" => [],
      "url" => "http://x"
    }

    assert {:ok, result} = Transforms.run(project.id, data)
    # Bravo created first (earlier updated_at) so runs before Alpha.
    assert result.data["content"] == "BA"
    assert result.errors == []
  end

  test "disabled transforms and transforms from other projects are skipped", %{project: project} do
    {:ok, other} =
      BDS.Projects.create_project(%{
        name: "Other",
        data_path:
          Path.join(
            System.tmp_dir!(),
            "bds-transforms-other-#{System.unique_integer([:positive])}"
          )
      })

    transform(
      project.id,
      "Disabled",
      """
      function main(data, _ctx)
        data.content = data.content .. "D"
        return data
      end
      """,
      enabled: false
    )

    transform(other.id, "Foreign", """
    function main(data, _ctx)
      data.content = data.content .. "F"
      return data
    end
    """)

    transform(project.id, "Enabled", """
    function main(data, _ctx)
      data.content = data.content .. "E"
      return data
    end
    """)

    data = %{
      "title" => "t",
      "content" => "",
      "tags" => [],
      "categories" => [],
      "url" => "http://x"
    }

    assert {:ok, result} = Transforms.run(project.id, data)
    assert result.data["content"] == "E"
  end

  test "pipeline continues after a failing transform, keeping last valid state", %{
    project: project
  } do
    transform(project.id, "First", """
    function main(data, _ctx)
      data.content = data.content .. "1"
      return data
    end
    """)

    Process.sleep(5)

    transform(project.id, "Boom", """
    function main(_data, _ctx)
      error("boom")
    end
    """)

    Process.sleep(5)

    transform(project.id, "Third", """
    function main(data, _ctx)
      data.content = data.content .. "3"
      return data
    end
    """)

    data = %{
      "title" => "t",
      "content" => "",
      "tags" => [],
      "categories" => [],
      "url" => "http://x"
    }

    assert {:ok, result} = Transforms.run(project.id, data)
    # Boom's failure does not roll back "1" and does not stop "3".
    assert result.data["content"] == "13"
    assert [%{reason: _}] = result.errors
  end

  test "a failing first transform does not halt the pipeline (TransformPipelineContinuation)", %{
    project: project
  } do
    # First transform fails before producing any valid state; later transforms
    # must still run against the original input, and each failure is captured
    # with its slug without halting the pipeline.
    boom =
      transform(project.id, "Boom", """
      function main(_data, _ctx)
        error("boom")
      end
      """)

    Process.sleep(5)

    transform(project.id, "Append", """
    function main(data, _ctx)
      data.content = data.content .. "A"
      return data
    end
    """)

    Process.sleep(5)

    kaboom =
      transform(project.id, "Kaboom", """
      function main(_data, _ctx)
        error("kaboom")
      end
      """)

    data = %{
      "title" => "t",
      "content" => "seed",
      "tags" => [],
      "categories" => [],
      "url" => "http://x"
    }

    assert {:ok, result} = Transforms.run(project.id, data)
    # Original input survives the first failure; the surviving transform still runs.
    assert result.data["content"] == "seedA"
    # Both failures are captured, in pipeline order, each tagged with its slug.
    assert [%{slug: first_slug}, %{slug: second_slug}] = result.errors
    assert first_slug == boom.slug
    assert second_slug == kaboom.slug
  end

  test "receives blogmark context with source and originating url", %{project: project} do
    transform(project.id, "Ctx", """
    function main(data, ctx)
      data.content = ctx.source .. "|" .. ctx.url
      return data
    end
    """)

    data = %{
      "title" => "t",
      "content" => "",
      "tags" => [],
      "categories" => [],
      "url" => "http://example.com/a"
    }

    assert {:ok, result} = Transforms.run(project.id, data)
    assert result.data["content"] == "blogmark|http://example.com/a"
  end

  test "per-script toast budget caps and truncates toasts", %{project: project} do
    long = String.duplicate("x", 500)

    transform(project.id, "Noisy", """
    function main(data, _ctx)
      local toasts = {}
      for i = 1, 10 do toasts[i] = "#{long}" end
      return { data = data, toasts = toasts }
    end
    """)

    data = %{
      "title" => "t",
      "content" => "",
      "tags" => [],
      "categories" => [],
      "url" => "http://x"
    }

    assert {:ok, result} = Transforms.run(project.id, data)
    # max 5 per script
    assert length(result.toasts) == 5
    # truncated to 300 chars
    assert Enum.all?(result.toasts, &(String.length(&1) == 300))
  end

  test "total toast budget caps across the whole pipeline", %{project: project} do
    body = """
    function main(data, _ctx)
      local toasts = {}
      for i = 1, 5 do toasts[i] = "msg" end
      return { data = data, toasts = toasts }
    end
    """

    # 5 transforms x 5 toasts each = 25 emitted, total budget is 20.
    for i <- 1..5 do
      transform(project.id, "T#{i}", body)
      Process.sleep(3)
    end

    data = %{
      "title" => "t",
      "content" => "",
      "tags" => [],
      "categories" => [],
      "url" => "http://x"
    }

    assert {:ok, result} = Transforms.run(project.id, data)
    assert length(result.toasts) == 20
  end
end
