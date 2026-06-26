defmodule BDS.Values do
  @moduledoc """
  Canonical scalar predicates for blank/present/truthy checks.

  These operate on individual values (not maps), which is why they live here
  rather than in `BDS.MapUtils`. `present?/1` and `blank?/1` use the same
  non-trimming contract as `BDS.MapUtils.blank_to_nil/1`: a whitespace-only
  string such as `" "` is considered **present**. Call sites that need
  trim-aware semantics must compose `String.trim/1` themselves.
  """

  @doc "Maps `nil` and `\"\"` to `nil`, everything else to itself (non-trimming)."
  @spec blank_to_nil(term()) :: term()
  defdelegate blank_to_nil(value), to: BDS.MapUtils

  @doc "True when `value` is neither `nil` nor `\"\"` (non-trimming)."
  @spec present?(term()) :: boolean()
  def present?(value), do: blank_to_nil(value) != nil

  @doc "True when `value` is `nil` or `\"\"` (non-trimming)."
  @spec blank?(term()) :: boolean()
  def blank?(value), do: blank_to_nil(value) == nil

  @doc "True for the canonical truthy set: `true`, `\"true\"`, `\"on\"`, `1`, `1.0`, `\"1\"`."
  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: value in [true, "true", "on", 1, 1.0, "1"]
end
