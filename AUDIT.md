# Elixir Antipattern Audit — Working Document

Verified 2026-06-25 against `lib/bds/` (233 modules). Every item below is a standalone task.
Follow `AGENTS.md`: test-first, fix all failures, clean build/credo/dialyzer/deps.audit.

---

## Task 1 — Delete the dead externally-driven task API

**File:** `lib/bds/tasks.ex` (573 lines, GenServer)

`tasks.ex` has two task patterns. One is live; one is dead.

- **Live (keep):** `submit_task/3` runs a work function under `Task.Supervisor`; the GenServer auto-tracks lifecycle via its `{ref, result}` and `{:DOWN, ...}` handlers, and progress flows through the `reporter` closure passed into the work function. Used by 8 call sites across 3 modules (`publishing.ex:57`; `auto_translation.ex:182,215`; `shell_commands.ex:83,94,219,418,554`). The read/control functions are also exposed through the Lua script API (`lib/bds/scripting/capabilities.ex:240-247`): `get`, `status_snapshot`, `cancel`, `get_all`, `get_running`, `clear_completed`.
- **Dead (delete):** the externally-driven pattern — register a task that runs elsewhere, then manually push progress and mark it complete/failed. Zero production callers; only `test/bds/tasks_test.exs` and `test/bds/scripting/api_test.exs` exercise it.

### Delete exactly these

Public functions and their matching `handle_call` clauses:

| Public function | `handle_call` clause |
|---|---|
| `register_external_task/2` (line 51) | line 166 |
| `report_progress/3` (line 55) | line 172 |
| `complete_task/2` (line 59) | line 176 |
| `fail_task/2` (line 63) | line 192 |

### Keep these — do NOT delete

- `submit_task/3`, `get_task/1`, `status_snapshot/0`, `list_tasks/0`, `list_running_tasks/0`, `cancel_task/1`, `clear_completed/0` — all live, most exposed via the script API.
- `clear_finished/0` (line 43) and its `handle_call` (line 120). It has zero production callers but is used as a test-reset helper in 5 test files (`tasks_test.exs:7`, `post_translations_test.exs:57`, `real_blog_rebuild_diagnostic_test.exs:41`, `shell_commands_test.exs:105`, `shell_live_test.exs:1409`). `clear_completed/0` is not a drop-in replacement — it clears only `:completed`, not `:failed`/`:cancelled`, and its semantics are documented in the script API.
- `maybe_report_progress/4` (private, line 347). It is shared: the `{:task_progress, ...}` `handle_info` (line 209) on the live path calls it. It does not become unused.

### Tests

- Delete only the test blocks in `tasks_test.exs` / `api_test.exs` that exclusively cover `register_external_task` / `report_progress` / `complete_task` / `fail_task`.
- Do NOT touch test setup/`on_exit` that calls `clear_finished/0` for reset — those tests do not cover it, they use it.

### Verify after

- `grep -rn "register_external_task\|complete_task\|fail_task" lib test` returns no hits.
- `grep -rn "Tasks.report_progress" lib test` returns no hits (`Maintenance.Progress.report_progress/4` and the script-side `bds.report_progress` are different functions — leave them).
- No deleted function is wired into `lib/bds/scripting/capabilities.ex` or `api_docs.ex` (confirmed: the script API exposes none of the four).
- Build/test/credo/dialyzer clean.

---

## Task 2 — Log silently-swallowed errors

**Pattern:** a `rescue`/`catch` clause that discards the error with no log line and returns a bare `:ok`, `nil`, or `:error` (e.g. `rescue _error -> :ok`, `catch :exit, _reason -> :ok`, `rescue _error -> nil`).

> **Inventory is non-exhaustive — treat the table as a starting set, not a closed list.**
> Before remediating, re-sweep with `grep -rnE "_(error|reason|exception|e) -> (nil|:ok|:error)" lib` (≈27 hits).
> The table below is not the full set — e.g. `main_window.ex` 174/175 returns `nil`, and `_error -> nil`
> sites exist in `scripting/capabilities/app_shell.ex:142` and `settings_editor/ai_settings.ex:174`. Triage all hits, not just the table.

| File | Lines | Clause / return |
|------|-------|-----------------|
| `lib/bds/desktop/shutdown.ex` | 5 `rescue` + 5 `catch` pairs: 27/29, 104/106, 122/124, 135/137, 160/162 | `_error -> :ok` / `:exit,_reason -> :ok` |
| `lib/bds/desktop/main_window.ex` | 24/25 | `catch :exit,_reason -> :ok` |
| `lib/bds/desktop/deep_link.ex` | 68/69 | `catch :exit,_reason -> :ok` |
| `lib/bds/git.ex` | 564/565 | `catch :error,_reason -> :ok` |
| `lib/bds/desktop/automation.ex` | 15/16, 222, 370/371 | `catch :exit -> :ok`, `rescue -> :ok`, `catch :error -> :ok` |
| `lib/bds/preview.ex` | 448 | `rescue _error -> :ok` |
| `lib/bds/desktop/shell_live/post_editor/list_values.ex` | 93 | `_error -> :ok` |
| `lib/bds/desktop/shell_live/import_editor/analysis_state.ex` | 283 | `_error -> :ok` |
| `lib/bds/desktop/shell_live/import_editor.ex` | 1420 | `_error -> :ok` |
| `lib/bds/desktop/shell_live/chat_editor.ex` | 999 | `_error -> :ok` |
| `lib/bds/mcp/server.ex` | 338 (`rescue` keyword), body 339 | `_error -> :ok` |
| `lib/bds/embeddings/index.ex` | 347/348 → `:ok`, **387/388 → `:error`** | both `rescue _exception -> ...` |

**Action:** add a log line to each swallowing clause without changing control flow or its return value. The recipe is per-clause, not a single find/replace — the var name and return value vary:
- `rescue`/`catch` returning `:ok` → bind the value and log, keep `:ok`: `error -> Logger.debug("swallowed in <ctx>: #{inspect(error)}"); :ok`
- The `index.ex:387` clause returns **`:error`**, not `:ok` — log, then keep returning `:error`. The `_error -> :ok` recipe does not apply here.
- `catch :exit,_reason`/`catch :error,_reason` clauses bind `_reason` (rename to `reason`), not `error`.

Use `Logger.warning` only where the error is genuinely unexpected.

**`shutdown.ex` / Wx-teardown exception:** the `shutdown.ex`, `main_window.ex`, and `deep_link.ex` catches wrap Wx event-table / `Desktop.Env` calls during teardown or headless startup. Use `Logger.debug` only — do not escalate to `warning`.

**Done when:** no `rescue`/`catch` clause in the listed files (plus any found by the re-sweep) discards its error without a log line, and every clause keeps its original return value.

---

## Task 3 — Add @spec to tasks.ex and embeddings.ex

| File | Public functions | Current @specs |
|------|------------------|----------------|
| `lib/bds/tasks.ex` | 10 non-callback public functions after Task 1 | 0 |
| `lib/bds/embeddings.ex` | 20 | 0 |

**Scope of "public functions":** spec every non-callback public function. In `tasks.ex` after deletion that is **10**: the 8 client-API functions (`submit_task/3`, `get_task/1`, `status_snapshot/0`, `list_tasks/0`, `list_running_tasks/0`, `clear_completed/0`, `clear_finished/0`, `cancel_task/1`) **plus** `start_link/1` (line 12) and `topic/0` (line 16) — `topic/0` is used outside the module (`shell_commands.ex:566`). Do NOT spec the three `@impl` GenServer callbacks (`init/1` line 67, `handle_call/3` line 79, `handle_info/2` line 208); `start_link/1` is **not** an `@impl` callback. (`tasks.ex` has 31 total public `def`s; 21 are callback clauses.) Limited to these two files — adjacent surfaces like `ai.ex` are already fully specced; this is not a repo-wide gap.

**Action:** add `@spec` to every public function. Run `mix dialyzer` to validate inferred types.
**Sequence:** do this after Task 1 so you don't spec the deleted functions.
**Done when:** 100% `@spec` coverage on public functions in both files; dialyzer clean.

---

## Task 4 — Dedup sidebar `maybe_where_all_*` helpers

**File:** `lib/bds/ui/sidebar.ex` (1,137 lines)

Three near-identical helpers — `maybe_where_all_tags/2` (429), `maybe_where_all_categories/2` (445), `maybe_where_all_media_tags/2` (695) — differing only in the JSON field name and one extra `AND lower(value) != 'page'` condition.

**Action:** extract one parametric helper, keeping the `(query, []) -> query` empty-list clauses. All three queries use a single positional binding, so do NOT pass a binding argument — parametrize over the JSON field atom and an optional "exclude page" flag, building the fragment with `field(x, ^field_atom)`:
```elixir
defp where_all_in_json_array(query, items, field_atom, exclude_page? \\ false)
```
Three ~15-line functions become one helper + three 2-line callers.
**Done when:** identical query output (verify via existing sidebar/search tests); build/credo clean.

---

## Task 5 — Enrich the AI facade @moduledoc (no code change)

**File:** `lib/bds/ai.ex` (210 lines)

This module is the stable public AI surface and the airplane-mode boundary required by `AGENTS.md`. It is NOT pure delegation: 8 functions hold real logic — `put_endpoint`, `get_endpoint`, `delete_endpoint`, `set_airplane_mode`, `airplane_mode?`, `airplane_endpoint_configured?`, `put_model_preference`, `get_model_preference`. It is used by 6 production modules (`posts/auto_translation.ex`, `scripting/capabilities/bridges.ex`, `chat_editor/message_build.ex`, `chat_editor/model_selection.ex`, `settings_editor/ai_settings.ex`, `sidebar_create.ex`). The MCP server does not use it (0 `BDS.AI` references in `lib/bds/mcp/`).

A `@moduledoc` already exists (line 2) but only describes endpoint/catalog/dispatch. **Action:** extend it to state that this module owns the airplane-mode / endpoint / model-preference logic and is the stable public AI surface, with `Catalog`/`OneShot`/`Chat` as internals. No code change.

---

## Task 6 — WITHDRAWN (already handled)

Original claim: `Task.async/1` in `sidebar_create.ex:50` result is never handled.

**False on current HEAD.** The parent LiveView already handles both the task
reply and the monitor-down path: `handle_info({ref, result}, ...)` at
`shell_live.ex:563` (→ `handle_file_picker_result/2`) and
`handle_info({:DOWN, ref, ...}, ...)` at `shell_live.ex:585`, both keyed on the
stored `file_picker_task` ref. The result is not lost.

Only remaining nit (not worth its own task): the picker uses `Task.async`
(linked) rather than `Task.Supervisor.async_nolink`, so a crash in the picker
task *could* take down the LiveView before `{:DOWN}` fires. Low-risk, not
zero-risk: `file_picker.ex` is a simple path that mostly returns tagged tuples.
No reproduced failure mode and no separate task — if `sidebar_create.ex:50` is
edited for another reason, switch `Task.async` → `Task.Supervisor.async_nolink`
opportunistically.

---

## Task 7 — Dedup `search_posts` / `search_media`

**File:** `lib/bds/search.ex` (862 lines)

Mirrored trios: `search_posts/3` (108) → `search_posts_blank/2` (118) → `search_posts_fts/3` (139), and `search_media/3` (182) → `search_media_blank/2` (192) → `search_media_fts/3` (213), plus `apply_post_filters/2` (254) / `apply_media_filters/2` (267). Same CTE+join FTS *pattern*.

**The shapes are NOT identical** (earlier "common `%{entities:}`" claim was wrong):
- Return maps differ by key: `%{posts: ...}` (132, 167) vs `%{media: ...}` (206, 241) — no shared `entities:` key.
- FTS subquery select + join keys differ: `post_id` (146, 152) vs `media_id` (220, 226).

**Action:** do NOT force one broad `search_entities/5`. Extract the genuinely shared *pieces* instead — blank-search query builder, FTS CTE/join setup (parametrized by FTS table + join-key column), and pagination assembly — and let each entity keep its own result key and filter function. Smaller shared helpers, not one generic mega-function.
**Caution:** FTS SQL and filter semantics must stay byte-identical per entity, and each public function must keep returning its existing `%{posts:}` / `%{media:}` shape — verify against existing search tests before and after.
**Done when:** all search tests pass unchanged; net line reduction; credo clean.

---

## Task 8 — Extract api_docs static data (only if recompile hurts)

**File:** `lib/bds/scripting/api_docs.ex` (1,554 lines)

A `@methods` module attribute of map literals, surfaced by a public `render/0`
(`api_docs.ex:1211`); any API change forces a full recompile. (The module is
not inert static data — the earlier "0 public functions" note was wrong.)

**Conditional, not a default cleanup.** Extracting to `priv/api_docs/methods.yaml`
(or JSON) loaded at startup trades compile-time structure for runtime schema
validation — a tradeoff, not a clear win. **Only do this after measuring actual
compile pain.** If recompile isn't hurting, skip. The API-docs-sync tests
(`AGENTS.md`) must still pass against the loaded data.

---

## Task 9 — Split oversized files (one per PR)

Guideline: no file > ~600 lines; split by responsibility.

| File | Lines | Notes |
|------|-------|-------|
| `scripting/api_docs.ex` | 1,554 | mostly data; if Task 8 runs it shrinks, but Task 8 is conditional/skippable — if skipped, split the non-data code here instead |
| `desktop/shell_live.ex` | 1,466 | 68 public functions — split into sub-modules; do this first |
| `ui/sidebar.ex` | 1,137 | shrinks after Task 4 |
| `ai/chat_tools.ex` | 1,096 | review for splitting |
| `ai/chat.ex` | 1,024 | review for splitting |
| `search.ex` | 862 | shrinks after Task 7; split → `search/posts.ex`, `search/media.ex`, `search/filters.ex` |

**Action:** lowest priority; one file per change set, each its own reviewable PR. Start with `shell_live.ex`.

---

## Order

1. Task 1 — delete dead task API (pure deletion, no behavior risk)
2. Task 2 — log swallowed errors
3. Task 3 — @specs (after Task 1)
4. Task 4 — sidebar dedup
5. Task 5 — AI facade moduledoc
6. ~~Task 6~~ — withdrawn (already handled in `shell_live.ex`)
7. Task 7 — search dedup
8. Task 8 — api_docs extract (conditional: only if recompile pain is measured)
9. Task 9 — file splitting (ongoing, lowest priority)
