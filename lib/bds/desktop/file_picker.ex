defmodule BDS.Desktop.FilePicker do
  @moduledoc false

  def choose_file(prompt) when is_binary(prompt) do
    if System.get_env("BDS_DESKTOP_AUTOMATION") == "1" do
      :cancel
    else
      case :os.type() do
        {:unix, :darwin} -> choose_file_macos(prompt)
        _other -> {:error, %{message: "File selection is only supported on macOS desktop"}}
      end
    end
  end

  defp choose_file_macos(prompt) do
    script = "POSIX path of (choose file with prompt \"#{escape_applescript(prompt)}\")"

    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> normalize_picker_failure(output)
    end
  end

  defp normalize_picker_failure(output) do
    message = String.trim(output)

    if message == "" or String.contains?(String.downcase(message), "canceled") do
      :cancel
    else
      {:error, %{message: message}}
    end
  end

  defp escape_applescript(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
