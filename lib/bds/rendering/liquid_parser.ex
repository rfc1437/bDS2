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
  """

  import NimbleParsec

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
