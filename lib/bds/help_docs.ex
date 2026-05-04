defmodule BDS.HelpDocs do
  @moduledoc false

  alias BDS.Scripting.ApiDocs
  use Gettext, backend: BDS.Gettext

  @documentation_path Path.expand("../../DOCUMENTATION.md", __DIR__)

  @type help_kind :: :documentation | :api_documentation

  @spec fetch(help_kind()) :: %{title: String.t(), subtitle: String.t(), markdown: String.t()}
  def fetch(:documentation) do
    %{
      title: dgettext("ui", "Documentation"),
      subtitle:
        dgettext(
          "ui",
          "End-user guidance for editorial workflows, media, templates, translation, and publishing in bDS2."
        ),
      markdown: documentation_markdown()
    }
  end

  def fetch(:api_documentation) do
    %{
      title: dgettext("ui", "API"),
      subtitle:
        dgettext(
          "ui",
          "Current Lua scripting contract rendered from the live bDS2 runtime."
        ),
      markdown: ApiDocs.render()
    }
  end

  @spec documentation_markdown() :: String.t()
  def documentation_markdown do
    case File.read(@documentation_path) do
      {:ok, contents} -> contents
      {:error, _reason} -> fallback_documentation()
    end
  end

  defp fallback_documentation do
    [
      "# bDS2 User Guide",
      "",
      "The project-level DOCUMENTATION.md file is missing.",
      "",
      "Use the repository root documentation file to provide the in-app user guide."
    ]
    |> Enum.join("\n")
  end
end
