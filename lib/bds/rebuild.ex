defmodule BDS.Rebuild do
  @moduledoc false

  def parallel_map(items, mapper, opts \\ []) when is_list(items) and is_function(mapper, 1) do
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    ordered = Keyword.get(opts, :ordered, true)
    timeout = Keyword.get(opts, :timeout, :infinity)

    items
    |> Task.async_stream(mapper, max_concurrency: max_concurrency, ordered: ordered, timeout: timeout)
    |> Enum.map(fn
      {:ok, item} -> item
      {:exit, reason} -> exit(reason)
    end)
  end
end
