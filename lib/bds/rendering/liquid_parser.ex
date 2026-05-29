defmodule BDS.Rendering.LiquidParser do
  @moduledoc """
  Restricted Liquid parser enforcing the `LiquidTagSubset` invariant
  (`specs/template.allium`).

  Only the tags used by the bundled starter templates are recognized:

    * `{% if %}` / `{% elsif %}` / `{% else %}` / `{% endif %}`
    * `{% for %}` / `{% endfor %}`
    * `{% assign %}`
    * `{% render 'partial', name: value %}`
    * `{{ object }}` output (and whitespace-stripped variants `{%- -%}` / `{{- -}}`)

  Any tag outside this subset (`unless`, `case`, `capture`, `raw`, `comment`,
  `cycle`, `tablerow`, `increment`, `decrement`, `liquid`, `echo`, `include`)
  leaves unmatched input and fails the `eos/0` check, producing a parse error.

  Pass this module as the second argument to `Liquex.parse/2` (and
  `Liquex.parse!/2`) so validation and rendering share the same surface.

  `validate/1` additionally enforces the `LiquidFilterSubset` invariant: only
  the four standard filters (`escape`, `url_encode`, `default`, `append`) and
  three custom filters (`i18n`, `markdown`, `slugify`) are permitted. Any other
  filter (`upcase`, `date`, `truncate`, `split`, `join`, …) is rejected even
  though Liquex would otherwise apply it as a built-in standard filter.

  `validate/1` also enforces the `LiquidOperatorSubset` invariant: only the
  `==` and `>` comparison operators are permitted (alongside the `and`/`or`
  logical operators and bare-variable truthiness). Any other comparison
  operator (`!=`, `<`, `>=`, `<=`, `contains`) is rejected even though Liquex
  would otherwise evaluate it.
  """

  import NimbleParsec

  # LiquidFilterSubset invariant (specs/template.allium).
  @allowed_filters ~w(escape url_encode default append i18n markdown slugify)

  # LiquidOperatorSubset invariant (specs/template.allium).
  @allowed_operators [:==, :>]

  @doc "The filter names permitted by the `LiquidFilterSubset` invariant."
  @spec allowed_filters() :: [String.t()]
  def allowed_filters, do: @allowed_filters

  @doc """
  Parses `source` with the restricted tag grammar and enforces the
  `LiquidFilterSubset` invariant.

  Returns `{:ok, ast}` on success, or `{:error, reason, line}` on a parse error
  or an unsupported filter (mirroring the `Liquex.parse/2` error shape so
  callers can treat both failures uniformly).
  """
  @spec validate(binary()) :: {:ok, term()} | {:error, term(), non_neg_integer()}
  def validate(source) when is_binary(source) do
    case Liquex.parse(source, __MODULE__) do
      {:ok, ast} ->
        with [] <- unsupported_filters(ast),
             [] <- unsupported_operators(ast) do
          {:ok, ast}
        else
          [{:filter, name} | _] -> {:error, "unsupported filter: #{name}", 0}
          [{:operator, op} | _] -> {:error, "unsupported operator: #{op}", 0}
        end

      {:error, _reason, _line} = error ->
        error
    end
  end

  @spec unsupported_filters(term()) :: [{:filter, String.t()}]
  defp unsupported_filters(ast) do
    ast
    |> collect_filters()
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @allowed_filters))
    |> Enum.map(&{:filter, &1})
  end

  @spec unsupported_operators(term()) :: [{:operator, String.t()}]
  defp unsupported_operators(ast) do
    ast
    |> collect_operators()
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @allowed_operators))
    |> Enum.map(&{:operator, operator_to_string(&1)})
  end

  @spec collect_filters(term()) :: [String.t()]
  defp collect_filters({:filter, [name | rest]}) when is_binary(name) do
    [name | collect_filters(rest)]
  end

  defp collect_filters(term) when is_tuple(term), do: collect_filters(Tuple.to_list(term))
  defp collect_filters(term) when is_list(term), do: Enum.flat_map(term, &collect_filters/1)
  defp collect_filters(_term), do: []

  @spec collect_operators(term()) :: [atom()]
  defp collect_operators({:op, op}) when is_atom(op), do: [op]
  defp collect_operators(term) when is_tuple(term), do: collect_operators(Tuple.to_list(term))
  defp collect_operators(term) when is_list(term), do: Enum.flat_map(term, &collect_operators/1)
  defp collect_operators(_term), do: []

  @spec operator_to_string(atom()) :: String.t()
  defp operator_to_string(:contains), do: "contains"
  defp operator_to_string(op), do: Atom.to_string(op)

  @tags [
    Liquex.Tag.AssignTag,
    Liquex.Tag.ForTag,
    Liquex.Tag.IfTag,
    Liquex.Tag.RenderTag,
    Liquex.Tag.ObjectTag
  ]

  tags_parser = Enum.map(@tags, &tag(&1.parse(), {:tag, &1}))

  # Ensure the tags are loaded into scope, otherwise function_exported? will
  # return false.
  Enum.each(@tags, &Code.ensure_loaded!/1)

  liquid_tags_parser =
    @tags
    |> Enum.filter(&function_exported?(&1, :parse_liquid_tag, 0))
    |> Enum.map(&tag(&1.parse_liquid_tag(), {:tag, &1}))
    |> choice()

  # Special case for leading spaces before `{%-` and `{{-`.
  leading_whitespace =
    empty()
    # credo:disable-for-lines:1
    |> Liquex.Parser.Literal.whitespace(1)
    |> lookahead(choice([string("{%-"), string("{{-")]))
    |> ignore()

  base =
    choice(
      tags_parser ++
        [
          # credo:disable-for-lines:2
          Liquex.Parser.Literal.text(),
          leading_whitespace
        ]
    )

  defcombinatorp(:document, repeat(base))
  defcombinatorp(:liquid_tag_contents, repeat(liquid_tags_parser))

  defparsec(:parse, parsec(:document) |> eos())
end
