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

  def choose_files(prompt, opts \\ []) when is_binary(prompt) do
    if System.get_env("BDS_DESKTOP_AUTOMATION") == "1" do
      :cancel
    else
      case :os.type() do
        {:unix, :darwin} -> choose_files_macos(prompt, opts)
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

  defp choose_files_macos(prompt, opts) do
    multiple = Keyword.get(opts, :multiple, false)
    image_only = Keyword.get(opts, :image_only, false)

    script_parts = ["POSIX path of (choose file with prompt \"#{escape_applescript(prompt)}\""]

    script_parts =
      if image_only do
        script_parts ++ [" of type {\"public.image\"}"]
      else
        script_parts
      end

    script_parts =
      if multiple do
        script_parts ++ [" with multiple selections allowed"]
      else
        script_parts
      end

    script = Enum.join(script_parts, "") <> ")"

    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {output, 0} -> parse_choose_files_result(String.trim(output), multiple)
      {output, _status} -> normalize_picker_failure(output)
    end
  end

  @doc false
  def parse_choose_files_result(output, true = _multiple) do
    paths =
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, paths}
  end

  @doc false
  def parse_choose_files_result(output, false = _multiple) do
    {:ok, output}
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
