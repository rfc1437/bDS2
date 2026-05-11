# Test Audit Procedure

Periodic review of the unit test suite to ensure every test exercises production
code against real assumptions and behavior.

## Scope

All `*_test.exs` files under `test/`.

## What counts as a valid unit test

A valid unit test **calls at least one production function** from `lib/bds/` and
**asserts on its return value, side effects, or observable behavior**.

Acceptable patterns:

- Calling a production function and asserting its return value.
- Calling a production function with injected test doubles (fake HTTP clients,
  fake runtimes) and asserting the production code's orchestration logic.
- Mounting a LiveView or rendering a LiveComponent and asserting HTML output
  or database state after interactions.
- Sending events to a GenServer and asserting state transitions.

### Source-property tests (acceptable, not flagged)

Tests that verify structural properties of source code are acceptable and should
not be flagged during this audit. Examples:

- Checking that all public functions have `@spec` annotations (AST parsing).
- Asserting absence of `String.to_atom` or `cond do` in specific files.
- Verifying CSS/JS/template assets contain expected class names or imports.
- Checking that `API.md` matches the output of a documentation generator.
- Verifying database indexes exist via `EXPLAIN QUERY PLAN`.
- Asserting `.allium` spec files have consistent parameter signatures.
- Checking config files for expected values.
- Verifying function decomposition patterns in source.

These are linting/contract/consistency checks. They serve a purpose but are
distinct from behavioral tests.

## What gets flagged

1. **Export-existence-only tests** — tests that call `function_exported?/3` or
   `Code.ensure_loaded?/1` without ever invoking the function. These verify
   compilation, not behavior. They are redundant when the same module is already
   tested via rendering or direct calls in another test file.

2. **Mock-only tests** — tests that define a fake/stub module and only assert
   on that fake's behavior without routing through any production code path.

3. **Trivially-passing tests** — tests whose assertions succeed regardless of
   whether the production code is correct (e.g., asserting on a hardcoded value
   that never touches production logic).

## How to run the audit

Ask Claude Code to:

> Analyse the unit tests of the project and check if all of them actually call
> proper production code or if there are tests that essentially only test
> scaffolds, mocks and helper functions. Every unit test must test proper
> production code against assumptions and behaviour. Source-property tests
> (structure, @spec, asset presence, schema verification, doc staleness) are
> acceptable and should not be flagged.

The audit should:

1. Read every `*_test.exs` file under `test/` in full.
2. For each test block, identify which production function (if any) is called.
3. Flag any test that falls into the categories above.
4. Report flagged tests with file path, line number, and explanation.

## Audit log

### 2026-05-11

Reviewed all 71 test files (69 after cleanup). Found 2 redundant files:

- `test/bds/desktop/shell_live/chat_editor_test.exs` — single test only called
  `function_exported?` for `ChatEditor`. The component was already fully tested
  via `render_component` in `shell_live_test.exs`. **Deleted.**

- `test/bds/desktop/shell_live/import_editor_test.exs` — single test only called
  `Code.ensure_loaded?` + `function_exported?` for `ImportEditor`. The component
  was already exercised in `import_shell_live_test.exs`. **Deleted.**

Result after cleanup: 646 tests, 0 failures, 4 skipped.
