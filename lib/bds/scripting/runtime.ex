defmodule BDS.Scripting.Runtime do
  @moduledoc """
  Behaviour for user-script runtimes hosted by bDS.

  The runtime boundary is intentionally narrow: syntax validation and
  bounded entrypoint execution.
  """

  @type source :: String.t()
  @type entrypoint :: String.t()
  @type args :: [term()]
  @type progress_event :: map()
  @type progress_callback :: (progress_event() -> any())
  @type execution_option ::
          {:timeout, non_neg_integer() | :infinity}
          | {:max_reductions, pos_integer() | :none}
          | {:spawn_opts, [term()]}
          | {:on_progress, progress_callback()}
          | {:capabilities, map()}

  @callback validate(source()) :: :ok | {:error, term()}
  @callback execute(source(), entrypoint(), args(), [execution_option()]) ::
              {:ok, term()} | {:error, term()}
end