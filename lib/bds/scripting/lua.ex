defmodule BDS.Scripting.Lua do
  @moduledoc """
  Lua runtime adapter backed by Luerl.

  Execution starts from a sandboxed Lua state. Host capabilities are explicit
  and opt-in.
  """

  @behaviour BDS.Scripting.Runtime

  @type lua_state :: tuple()
  @type runtime_result :: {:ok, term(), lua_state} | {:error, term()}

  @impl true
  def validate(source) when is_binary(source) do
    case :luerl.load(source, :luerl_sandbox.init()) do
      {:ok, _chunk, _state} ->
        :ok

      {:error, errors, warnings} ->
        {:error, {:compile_error, %{errors: errors, warnings: warnings}}}
    end
  end

  @impl true
  def execute(source, entrypoint, args, opts)
      when is_binary(source) and is_binary(entrypoint) and is_list(args) and is_list(opts) do
    with {:ok, state} <- initial_state(opts),
         {:ok, state} <- put_args(state, args),
         {:ok, result, next_state} <- run_entrypoint(source, entrypoint, state, opts) do
      {:ok, decode_result(result, next_state)}
    end
  end

  defp initial_state(opts) do
    state = :luerl_sandbox.init()
    capabilities = Keyword.get(opts, :capabilities, %{})

    with {:ok, state} <- :luerl.set_table_keys_dec(["bds"], %{}, state),
         {:ok, state} <- install_progress_callback(state, Keyword.get(opts, :on_progress)),
         {:ok, state} <- install_capabilities(state, capabilities) do
      {:ok, state}
    end
  end

  defp install_progress_callback(state, nil), do: {:ok, state}

  defp install_progress_callback(state, callback) when is_function(callback, 1) do
    progress_function = fn args, current_state ->
      decoded_args = :luerl.decode_list(args, current_state)

      progress_event =
        case decoded_args do
          [payload | _] when is_map(payload) -> payload
          [payload | _] -> normalize_progress_payload(payload)
          [] -> %{}
        end

      callback.(progress_event)
      :luerl.encode_list([true], current_state)
    end

    case :luerl.set_table_keys_dec(["bds", "report_progress"], progress_function, state) do
      {:ok, next_state} -> {:ok, next_state}
      error -> {:error, {:progress_callback_install_failed, error}}
    end
  end

  defp install_progress_callback(_state, callback),
    do: {:error, {:invalid_progress_callback, callback}}

  defp install_capabilities(state, capabilities) when capabilities in [%{}, []], do: {:ok, state}

  defp install_capabilities(state, capabilities) when is_map(capabilities) do
    Enum.reduce_while(capabilities, {:ok, state}, fn {name, value}, {:ok, current_state} ->
      case install_capability(["bds", to_string(name)], value, current_state) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp install_capabilities(_state, capabilities),
    do: {:error, {:invalid_capabilities, capabilities}}

  defp install_capability(path, value, state) when is_map(value) do
    with {:ok, seeded_state} <- set_capability(path, %{}, state) do
      Enum.reduce_while(value, {:ok, seeded_state}, fn {name, nested_value},
                                                       {:ok, current_state} ->
        case install_capability(path ++ [to_string(name)], nested_value, current_state) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp install_capability(path, value, state) do
    set_capability(path, value, state)
  end

  defp set_capability(path, value, state) do
    case :luerl.set_table_keys_dec(path, value, state) do
      {:ok, next_state} -> {:ok, next_state}
      error -> {:error, {:capability_install_failed, path, error}}
    end
  end

  defp normalize_progress_payload(payload) when is_list(payload) do
    if Enum.all?(payload, &match?({key, _value} when is_binary(key) or is_atom(key), &1)) do
      Map.new(payload, fn {key, value} -> {to_string(key), value} end)
    else
      %{value: payload}
    end
  end

  defp normalize_progress_payload(payload), do: %{value: payload}

  defp put_args(state, args) do
    case Luerl.set_table_keys_dec(state, ["__bds_args__"], args) do
      {:ok, next_state} -> {:ok, next_state}
      error -> {:error, {:argument_encoding_failed, error}}
    end
  end

  @spec run_entrypoint(binary(), binary(), lua_state, keyword()) :: runtime_result
  defp run_entrypoint(source, entrypoint, state, opts) do
    script =
      IO.iodata_to_binary([
        source,
        "\nreturn ",
        entrypoint,
        "(table.unpack(__bds_args__))\n"
      ])
      |> String.to_charlist()

    script
    |> then(&sandbox_run(&1, sandbox_flags(opts), state))
    |> normalize_sandbox_result()
  end

  @spec sandbox_run(term(), term(), lua_state) :: term()
  defp sandbox_run(script, flags, state), do: apply(:luerl_sandbox, :run, [script, flags, state])

  defp normalize_sandbox_result({:ok, result, next_state}), do: {:ok, result, next_state}

  defp normalize_sandbox_result({:error, {:reductions, count}}),
    do: {:error, {:reductions_exceeded, count}}

  defp normalize_sandbox_result({:error, :timeout}), do: {:error, :timeout}
  defp normalize_sandbox_result({:error, reason}), do: {:error, reason}

  defp normalize_sandbox_result({reply, next_state}) when is_tuple(next_state) do
    case reply do
      {:ok, result} -> {:ok, result, next_state}
      {:ok, result, _reply_state} -> {:ok, result, next_state}
      {:error, {:reductions, count}} -> {:error, {:reductions_exceeded, count}}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, {other, next_state}}}
    end
  end

  defp normalize_sandbox_result(other), do: {:error, {:unexpected_result, other}}

  defp sandbox_flags(opts) do
    config = Application.fetch_env!(:bds, :scripting)

    [
      max_time: Keyword.get(opts, :timeout, Keyword.fetch!(config, :timeout)),
      max_reductions: Keyword.get(opts, :max_reductions, Keyword.fetch!(config, :max_reductions)),
      spawn_opts: Keyword.get(opts, :spawn_opts, [])
    ]
  end

  defp decode_result(values, state) when is_list(values) do
    values
    |> Enum.map(&decode_result(&1, state))
    |> unwrap_result()
  end

  defp decode_result(value, state) do
    value
    |> :luerl.decode(state)
    |> normalize_decoded_value()
  end

  defp normalize_decoded_value(values) when is_list(values) do
    if Enum.all?(values, &match?({key, _value} when is_binary(key) or is_atom(key), &1)) do
      Map.new(values, fn {key, value} -> {to_string(key), value} end)
    else
      Enum.map(values, &normalize_decoded_value/1)
    end
  end

  defp normalize_decoded_value(value), do: value

  defp unwrap_result(values) when is_list(values) do
    case values do
      [] -> nil
      [value] -> value
      _values -> values
    end
  end
end
