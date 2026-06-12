%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/", "mix.exs"],
        excluded: [~r"/deps/", ~r"/_build/", ~r"/priv/static/"]
      },
      strict: true,
      parse_timeout: 10_000,
      color: true,
      checks: [
        {Credo.Check.Consistency.ExceptionNames},
        {Credo.Check.Consistency.LineEndings},
        {Credo.Check.Consistency.SpaceAroundOperators},
        {Credo.Check.Consistency.SpaceInParentheses},
        {Credo.Check.Consistency.TabsOrSpaces},
        {Credo.Check.Design.AliasUsage, false},
        {Credo.Check.Readability.BlockPipe, false},
        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Readability.LargeNumbers, false},
        {Credo.Check.Readability.MaxLineLength, false},
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Readability.PreferImplicitTry, false},
        {Credo.Check.Readability.Semicolons, false},
        {Credo.Check.Readability.StringSigils, false},
        {Credo.Check.Readability.TrailingBlankLine, false},
        {Credo.Check.Readability.UnnecessaryAliasExpansion, false},
        {Credo.Check.Readability.WithSingleClause, false},
        {Credo.Check.Refactor.Apply, false},
        {Credo.Check.Refactor.CondStatements, false},
        {Credo.Check.Refactor.CyclomaticComplexity, false},
        {Credo.Check.Refactor.FilterFilter, false},
        {Credo.Check.Refactor.FilterReject, false},
        {Credo.Check.Refactor.FunctionArity, false},
        {Credo.Check.Refactor.MapJoin, false},
        {Credo.Check.Refactor.Nesting, false},
        {Credo.Check.Refactor.NegatedConditionsWithElse, false},
        {Credo.Check.Refactor.RejectFilter, false},
        {Credo.Check.Refactor.RejectReject, false},
        {Credo.Check.Refactor.RedundantWithClauseResult, false},
        {Credo.Check.Warning.ApplicationConfigInModuleAttribute},
        {Credo.Check.Warning.BoolOperationOnSameValues},
        {Credo.Check.Warning.ExpensiveEmptyEnumCheck},
        {Credo.Check.Warning.IExPry},
        {Credo.Check.Warning.LazyLogging},
        {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, false},
        {Credo.Check.Warning.OperationOnSameValues},
        {Credo.Check.Warning.RaiseInsideRescue}
      ]
    }
  ]
}