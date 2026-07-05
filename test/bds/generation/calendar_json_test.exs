defmodule BDS.Generation.CalendarJsonTest do
  use ExUnit.Case, async: true

  alias BDS.Generation.Paths
  alias BDS.Generation.Sitemap

  defp unix_ms(date_string) do
    # Local-noon timestamp so the local-time date matches date_string regardless of TZ.
    date = Date.from_iso8601!(date_string)
    naive = NaiveDateTime.new!(date, ~T[12:00:00])
    :calendar.local_time_to_universal_time_dst(NaiveDateTime.to_erl(naive))
    |> List.first()
    |> :calendar.datetime_to_gregorian_seconds()
    |> Kernel.-(62_167_219_200)
    |> Kernel.*(1000)
  end

  defp post(date_string, slug) do
    %{created_at: unix_ms(date_string), slug: slug, title: slug}
  end

  test "render_calendar emits years/months/days count maps for the calendar runtime" do
    posts = [
      post("2024-05-17", "a"),
      post("2024-05-17", "b"),
      post("2024-06-01", "c"),
      post("2023-12-31", "d")
    ]

    decoded = posts |> Sitemap.render_calendar() |> Jason.decode!()

    assert decoded == %{
             "years" => %{"2024" => 3, "2023" => 1},
             "months" => %{"2024-05" => 2, "2024-06" => 1, "2023-12" => 1},
             "days" => %{
               "2024-05-17" => 2,
               "2024-06-01" => 1,
               "2023-12-31" => 1
             }
           }
  end

  test "render_calendar of no posts emits empty count maps" do
    assert Sitemap.render_calendar([]) |> Jason.decode!() ==
             %{"years" => %{}, "months" => %{}, "days" => %{}}
  end

  test "day keys use the local date used for post routes" do
    ts = unix_ms("2024-05-17")
    decoded = Sitemap.render_calendar([%{created_at: ts, slug: "a", title: "a"}]) |> Jason.decode!()
    assert Map.keys(decoded["days"]) == [Paths.local_date_iso8601!(ts)]
  end
end
