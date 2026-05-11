# Spec Audit Process

This document describes the repeatable process for auditing the Allium specifications against the bDS2 codebase and test suite. Run it whenever specs or code change materially.

## Overview

The audit produces three categories of findings:

1. **Spec-claims-not-in-code** — spec describes behavior the code does not implement
2. **Code-not-in-spec** — code implements behavior the spec does not describe
3. **Spec-claims-not-in-tests** — spec invariants/rules/behaviors lack test coverage

## Step 1: Map the Territory

```bash
# List all spec files
ls specs/*.allium

# List all source modules
ls lib/bds/ lib/bds/**/

# List all test files
ls test/bds/ test/bds/**/
```

Record the mapping between specs and code/test files. Use `specs/bds.allium` as the index — it lists every `use` directive with its domain label.

## Step 2: Extract Spec Claims

For each `.allium` file, extract:

| Claim Type | Pattern | Example |
|---|---|---|
| **invariant** | `invariant Name:` or lines describing always-true properties | `UniqueSlugPerProject: slugs unique within project` |
| **rule** | `rule Name { requires: ... ensures: ... }` | `CreatePost: creates with slug, status=draft` |
| **guarantee** | `guarantee Name:` | `SandboxedExecution: no filesystem/process loading` |
| **config** | `config { key = value }` | `macro_timeout = 10.seconds` |
| **behavior** | Explicit claims in comments or entity descriptions | `"HomeAlwaysPresent: menu always has Home entry"` |

Record the spec file name, claim name, claim type, and line number for each.

## Step 3: Compare Spec Claims Against Code

For each claim, find the corresponding code and verify:

### 3a. Entity/field existence
- Does the Ecto schema have the fields the spec declares?
- Are relationships (has_many, belongs_to) present?
- Are enum/status values complete?

```bash
# Check schema fields
grep -n "field :" lib/bds/posts/post.ex
grep -n "has_many\|belongs_to" lib/bds/posts/post.ex
```

### 3b. Rule implementation
- Does the code enforce the `requires` preconditions?
- Does the code produce the `ensures` postconditions?
- Are side-effects (FTS, embeddings, file writes) triggered?

```bash
# Check function implementation
grep -n "def create_post" lib/bds/posts.ex
grep -n "def publish_post" lib/bds/posts.ex
```

### 3c. Invariant enforcement
- Are constraints enforced at the schema level (unique_index, check_constraint)?
- Are constraints enforced in changeset validations?
- Are constraints enforced in business logic?

```bash
# Check database constraints
grep -n "unique_index\|check_constraint" priv/repo/migrations/*.ex
grep -n "unique_constraint\|validate_" lib/bds/posts/post.ex
```

### 3d. File format compliance
- Does the serialization format match the spec's frontmatter values?
- Are conditional fields omitted when falsy?
- Are required fields always present?

```bash
# Check serialization
grep -n "serialize\|write_file\|Frontmatter" lib/bds/frontmatter.ex lib/bds/posts/file_sync.ex
```

## Step 4: Compare Code Against Spec Claims

Search for code that implements behavior NOT described in any spec:

### 4a. Public API functions not in any spec rule
```bash
# List public functions in a module
grep -n "def " lib/bds/posts.ex | grep -v "defp"
```

### 4b. Schema fields not in any spec entity
```bash
# List all fields
grep -n "field :" lib/bds/posts/post.ex
```

### 4c. Side effects not in engine_side_effects.allium
```bash
# Check what happens after CRUD operations
grep -n "sync_post\|sync_media\|Search\.\|Embeddings\.\|AutoTranslation" lib/bds/posts.ex lib/bds/media.ex
```

### 4d. UI features not in any editor spec
```bash
# Check HEEx templates for UI elements
grep -n "phx-click\|data-phx-" lib/bds/desktop/post_editor_html/post_editor.html.heex
```

## Step 5: Compare Spec Claims Against Tests

For each invariant, rule, and guarantee, search for a test that verifies it:

### 5a. Direct test search
```bash
# Search test names and bodies
grep -rn "test \"" test/bds/posts_test.exs | head -30
grep -rn "test \"" test/bds/media_test.exs | head -30
```

### 5b. Invariant coverage check
For each invariant, determine:
- **YES**: Test explicitly verifies the invariant (creates violation, expects rejection)
- **PARTIAL**: Test verifies the happy path but not violation scenarios
- **NO**: No test exists

### 5c. Rule coverage check
For each rule, determine:
- **YES**: Test exercises `requires` precondition and `ensures` postcondition
- **PARTIAL**: Test exercises the happy path but not preconditions or all postconditions
- **NO**: No test exists

### 5d. Side-effect chain coverage
For each side-effect rule in `engine_side_effects.allium`, check whether a test verifies ALL `ensures` clauses fire together (not just individually).

## Step 6: Classify Findings

Each gap falls into one of these categories with a recommended action:

| Category | Direction | Action |
|---|---|---|
| **Spec correct, code wrong** | Spec → Code | Fix the code |
| **Code correct, spec drifted** | Code → Spec | Update the spec |
| **Code behavior, no spec** | Code → Spec | Distill into spec |
| **Spec claim, no test** | Spec → Test | Write test |
| **Internal spec inconsistency** | Spec → Spec | Align specs |
| **Decision needed** | Both | Resolve with stakeholder |

## Step 7: Produce SPECGAPS.md

Consolidate all findings into `SPECGAPS.md` with:
- Gap ID for tracking
- Clear description of the gap
- Which spec file and line
- Which code file and line
- Recommended path (fix code / update spec / write test / decide)
- Priority (HIGH/MEDIUM/LOW)

## Step 8: Validate

After making changes:
```bash
# Run full test suite
mix test

# Run dialyzer
mix dialyzer

# Validate allium specs (if tool available)
# Use the allium CLI to validate spec files
```

## Re-running the Audit

1. Start from Step 2 — re-extract claims from updated specs
2. Run Steps 3-5 against current code and tests
3. Compare against previous SPECGAPS.md to identify resolved and new gaps
4. Update SPECGAPS.md

The audit should be re-run after:
- Adding new spec files or significant spec changes
- Adding new features or refactoring code
- Adding new test files
- Before any release milestone
