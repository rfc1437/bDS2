defmodule BDS.Desktop.FolderPicker do
  @moduledoc false

  def choose_directory(prompt) when is_binary(prompt) do
    case :os.type() do
      {:unix, :darwin} -> choose_directory_macos(prompt)
      _other -> {:error, %{message: "Folder selection is only supported on macOS desktop"}}
    end
  end

  defp choose_directory_macos(prompt) do
    script = "POSIX path of (choose folder with prompt \"#{escape_applescript(prompt)}\")"

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
