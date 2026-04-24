defmodule BDS.Desktop.ShellController do
  @moduledoc false

  def index_html do
    File.read!(Application.app_dir(:bds, ["priv", "ui", "index.html"]))
  end
end
