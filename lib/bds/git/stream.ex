defmodule BDS.Git.Stream do
  @moduledoc """
  Runs a git command and streams its output to a subscriber process as it
  arrives, keeping stdout and stderr on separate channels.

  A plain Erlang port merges stderr into stdout, so we redirect the command's
  stderr through a FIFO (`sh -c 'exec "$0" "$@" 2>fifo'`) and read that FIFO with
  a second `cat` port. `sh`, `cat` and `mkfifo` are system binaries, so no extra
  dependency is bundled.

  The subscriber receives:

    * `{:git_output, ref, :stdout, chunk}`
    * `{:git_output, ref, :stderr, chunk}`
    * `{:git_done, ref, exit_status}` (`0` on success)

  Send `cancel/1` to terminate a hanging command; the OS process is killed and a
  `{:git_done, ref, status}` still follows.
  """

  @drain_ms 200

  @spec start(pid, String.t(), [String.t()], keyword) :: {:ok, pid, reference}
  def start(subscriber, cwd, args, opts \\ [])
      when is_pid(subscriber) and is_binary(cwd) and is_list(args) do
    ref = make_ref()
    pid = spawn(fn -> init(subscriber, ref, cwd, args, opts) end)
    {:ok, pid, ref}
  end

  @spec cancel(pid) :: :ok
  def cancel(pid) when is_pid(pid) do
    send(pid, :cancel)
    :ok
  end

  defp init(subscriber, ref, cwd, args, opts) do
    command = Keyword.get(opts, :command, "git")
    env = Keyword.get(opts, :env, %{})

    case System.find_executable(command) do
      nil ->
        send(subscriber, {:git_output, ref, :stderr, "missing executable: #{command}\n"})
        send(subscriber, {:git_done, ref, 127})

      executable ->
        run(subscriber, ref, cwd, executable, args, env)
    end
  end

  defp run(subscriber, ref, cwd, executable, args, env) do
    fifo_dir = Path.join(System.tmp_dir!(), "bds-git-fifo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(fifo_dir)
    fifo = Path.join(fifo_dir, "stderr")

    try do
      {_out, 0} = System.cmd("mkfifo", [fifo])

      # exec replaces sh with the target binary, so the OS pid and exit status we
      # observe on this port are the command's own.
      script = ~s(exec "$0" "$@" 2>'#{fifo}')

      out_port =
        Port.open(
          {:spawn_executable, System.find_executable("sh")},
          [
            :binary,
            :exit_status,
            :use_stdio,
            :hide,
            {:cd, cwd},
            {:env, port_env(env)},
            {:args, ["-c", script, executable | args]}
          ]
        )

      err_port =
        Port.open(
          {:spawn_executable, System.find_executable("cat")},
          [:binary, :exit_status, :use_stdio, :hide, {:args, [fifo]}]
        )

      loop(subscriber, ref, out_port, err_port)
    after
      File.rm_rf(fifo_dir)
    end
  end

  defp loop(subscriber, ref, out_port, err_port) do
    receive do
      {^out_port, {:data, data}} ->
        send(subscriber, {:git_output, ref, :stdout, data})
        loop(subscriber, ref, out_port, err_port)

      {^err_port, {:data, data}} ->
        send(subscriber, {:git_output, ref, :stderr, data})
        loop(subscriber, ref, out_port, err_port)

      {^err_port, {:exit_status, _status}} ->
        loop(subscriber, ref, out_port, nil)

      {^out_port, {:exit_status, status}} ->
        drain(subscriber, ref, err_port)
        send(subscriber, {:git_done, ref, status})

      :cancel ->
        kill(out_port)
        loop(subscriber, ref, out_port, err_port)
    end
  end

  defp drain(_subscriber, _ref, nil), do: :ok

  defp drain(subscriber, ref, err_port) do
    receive do
      {^err_port, {:data, data}} ->
        send(subscriber, {:git_output, ref, :stderr, data})
        drain(subscriber, ref, err_port)

      {^err_port, {:exit_status, _status}} ->
        :ok
    after
      @drain_ms -> :ok
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) ->
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _other ->
        :ok
    end
  end

  defp port_env(env) do
    Enum.map(env, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end
end
