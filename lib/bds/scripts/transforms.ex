defmodule BDS.Scripts.Transforms do
  @moduledoc """
  Runs the blogmark transform pipeline (spec: script.allium `ExecuteTransform`).

  Enabled `transform` scripts for a project are applied sequentially to a post
  candidate produced by a `bds2://new-post` blogmark deep link. Each transform
  receives the current candidate plus a context describing the blogmark source
  and origin URL, and returns the modified candidate.

  Guarantees enforced here:

    * `TransformTrigger` — each script receives the candidate plus
      `{source = "blogmark", url = ...}` context.
    * `TransformPipelineContinuation` — a transform error is captured per script
      and does not roll back the last valid candidate; the pipeline continues.
    * `TransformToastBudget` — at most `transform_max_toasts_per_script` toasts
      are accepted from any one transform, with a total budget of
      `transform_max_toasts_total`, each truncated to
      `transform_max_toast_length` characters.
  """

  require Logger

  alias BDS.Scripts
  alias BDS.Scripts.Script
  alias BDS.Scripting
  alias BDS.Scripting.Capabilities.Util

  @type data :: %{optional(String.t()) => term()}
  @type result :: %{
          data: data(),
          toasts: [String.t()],
          errors: [%{slug: String.t() | nil, reason: term()}]
        }

  @doc """
  Applies every enabled transform script for `project_id` to `data` in order.

  Returns `{:ok, %{data:, toasts:, errors:}}` where `data` is the final
  candidate, `toasts` are the budget-enforced messages accepted across the
  pipeline, and `errors` records any transforms that failed.
  """
  @spec run(String.t(), data(), keyword()) :: {:ok, result()}
  def run(project_id, data, opts \\ [])
      when is_binary(project_id) and is_map(data) and is_list(opts) do
    context = %{"source" => "blogmark", "url" => Map.get(data, "url")}
    transforms = Scripts.list_transform_scripts(project_id)

    initial = %{data: data, toasts: [], errors: [], toast_total: 0}

    final =
      Enum.reduce(transforms, initial, fn script, acc ->
        apply_transform(project_id, script, context, acc, opts)
      end)

    {:ok,
     %{data: final.data, toasts: Enum.reverse(final.toasts), errors: Enum.reverse(final.errors)}}
  end

  defp apply_transform(_project_id, %Script{entrypoint: entry}, _context, acc, _opts)
       when entry in [nil, ""] do
    acc
  end

  defp apply_transform(project_id, %Script{} = script, context, acc, opts) do
    source = Scripts.resolved_content(script)

    case Scripting.execute_project_script(
           project_id,
           source,
           script.entrypoint,
           [acc.data, context],
           opts
         ) do
      {:ok, returned} ->
        {next_data, raw_toasts} = split_return(Util.normalize_input(returned), acc.data)
        accept_toasts(%{acc | data: next_data}, raw_toasts)

      {:error, reason} ->
        Logger.warning("transform #{script.slug} failed: #{inspect(reason)}")
        %{acc | errors: [%{slug: script.slug, reason: reason} | acc.errors]}
    end
  end

  # A transform may return either the candidate map directly, or a wrapper
  # `{ data = <candidate>, toasts = [...] }`. Blogmark candidates never carry a
  # nested "data" map, so the wrapper shape is unambiguous.
  defp split_return(%{"data" => %{} = inner} = wrapper, _previous) do
    {inner, toast_list(Map.get(wrapper, "toasts"))}
  end

  defp split_return(returned, _previous) when is_map(returned), do: {returned, []}
  defp split_return(_returned, previous), do: {previous, []}

  defp toast_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp toast_list(_other), do: []

  defp accept_toasts(acc, raw_toasts) do
    per_script_max = config(:transform_max_toasts_per_script, 5)
    total_max = config(:transform_max_toasts_total, 20)
    max_length = config(:transform_max_toast_length, 300)

    raw_toasts
    |> Enum.take(per_script_max)
    |> Enum.reduce(acc, fn message, inner_acc ->
      if inner_acc.toast_total >= total_max do
        inner_acc
      else
        truncated = truncate(message, max_length)

        %{
          inner_acc
          | toasts: [truncated | inner_acc.toasts],
            toast_total: inner_acc.toast_total + 1
        }
      end
    end)
  end

  defp truncate(message, max_length) do
    if String.length(message) > max_length do
      String.slice(message, 0, max_length)
    else
      message
    end
  end

  defp config(key, default) do
    :bds
    |> Application.fetch_env!(:scripting)
    |> Keyword.get(key, default)
  end
end
