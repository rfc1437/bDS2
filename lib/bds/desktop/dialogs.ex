defmodule BDS.Desktop.Dialogs do
  @moduledoc false

  # Native single-line text prompt, same osascript approach as
  # BDS.Desktop.FilePicker. Returns {:ok, text} | :cancel | {:error, map}.
  def prompt_text(message, default \\ "") when is_binary(message) do
    if System.get_env("BDS_DESKTOP_AUTOMATION") == "1" do
      :cancel
    else
      case :os.type() do
        {:unix, :darwin} -> prompt_text_macos(message, default)
        _other -> {:error, %{message: "Dialogs are only supported on macOS desktop"}}
      end
    end
  end

  def alert(title, message) when is_binary(title) and is_binary(message) do
    if System.get_env("BDS_DESKTOP_AUTOMATION") == "1" or :os.type() != {:unix, :darwin} do
      :ok
    else
      script = "display alert \"#{escape(title)}\" message \"#{escape(message)}\""
      _ = System.cmd("osascript", ["-e", script], stderr_to_stdout: true)
      :ok
    end
  end

  defp prompt_text_macos(message, default) do
    script =
      "text returned of (display dialog \"#{escape(message)}\" default answer \"#{escape(default)}\")"

    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> normalize_failure(output)
    end
  end

  defp normalize_failure(output) do
    message = String.trim(output)

    if message == "" or String.contains?(String.downcase(message), "canceled") do
      :cancel
    else
      {:error, %{message: message}}
    end
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
