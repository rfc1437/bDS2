defmodule BDS.Desktop.ExternalLinks do
  @moduledoc false

  @github_url "https://github.com/rfc1437/bDS2"
  @github_issues_url "#{@github_url}/issues"

  @spec github_url() :: String.t()
  def github_url, do: @github_url

  @spec github_issues_url() :: String.t()
  def github_issues_url, do: @github_issues_url
end
