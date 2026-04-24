defmodule BDS.Desktop.ShellController do
  @moduledoc false

  def index_html do
    BDS.UI.ShellPage.render()
  end

  def task_status_json do
    Jason.encode!(BDS.Tasks.status_snapshot())
  end

  def command_json(payload) when is_map(payload) do
    action = Map.get(payload, "action") || Map.get(payload, :action)
    params = Map.get(payload, "params") || Map.get(payload, :params) || %{}

    case BDS.Desktop.ShellCommands.execute(action, params) do
      {:ok, result} -> Jason.encode!(%{status: "ok", result: result})
      {:error, error} -> Jason.encode!(%{status: "error", error: normalize_error(error)})
    end
  end

  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error), do: %{message: inspect(error)}
end
