# Elixir Code Smell Analysis — bDS2

Living document. Each section lists **status**, then **open work in priority order**, then a brief notes block. Completed work is listed compactly at the bottom (`## Changelog`).

Last refreshed: 2026-05-01.

---

## 1. God Modules

**Status:** in progress. Five originally-flagged god modules are reduced to coordinator size; eight new files (mostly LiveView editors) crossed the 800-line threshold and are now the active queue.

### Open queue (priority order)

| # | Module | Current lines | Target | Strategy |
|---|---|---|---|---|
| 1 | `BDS.Maintenance` | 810 | ≤ 250 | Extract `DiffReports` (~240), `DiffComputation` (~160), `Repair` (~160), `FileScan` (~140), `Progress` (~60). Coordinator keeps the 4 public entrypoints. |
| 2 | `BDS.Media` | 993 | ≤ 250 | Extract `Thumbnails` (~140), `Sidecars` (~150), `FileOps` (~180), `Rebuild` (~130), `Linking` (~80). Main keeps CRUD + translation API. |
| 3 | `BDS.Desktop.ShellLive.ImportEditor` | 1436 | ≤ 600 | Extract `ConflictResolution` (~150), `TaxonomyEditing` (~120), `AnalysisState` (~150), `ProgressTracking` (~120). Components stay in main file. |
| 4 | `BDS.Rendering` | 838 | ≤ 200 | Extract `TemplateSelection` (~120), `PostRendering` (~180), `ListArchive` (~150), `Metadata` (~140), `LinksAndLanguages` (~100). Main keeps the 3 public renders. |
| 5 | `BDS.Desktop.ShellLive.MenuEditor` | 871 | ≤ 350 | Extract `TreeOps` (~280), `TreePredicates` (~60), `DraftManagement` (~140), `PageCategory` (~120), `State` (~80). |
| 6 | `BDS.Desktop.ShellLive.PostEditor` | 963 | ≤ 400 | Extract `DraftManagement` (~180), `ListValues` (~160), `Persistence` (~140), `PostMetadata` (~150). |
| 7 | `BDS.Desktop.ShellLive.SettingsEditor` | 872 | ≤ 350 | Extract `ProjectSettings` (~140), `AISettings` (~150), `PublishingSettings` (~80), `ManagedCategories` (~140), `StyleEditor` (~80), `MCPConfig` (~60). |
| 8 | `BDS.Desktop.ShellLive.ChatEditor` | 972 | ≤ 400 | Extract `ToolSurfaces` (~280), `ToolTracking` (~140), `MessageBuild` (~160), `ModelSelection` (~100). Defer — highest internal coupling. |
| 9 | `BDS.MCP` | 677 | ≤ 350 | Split tools / resources / proposals / serialization clusters. (Carried over from original priority list.) |

**Established pattern:** extract cohesive helper clusters into submodules under `lib/<context>/<sub>.ex`; `import BDS.X.Y, only: [...]` from the main module so internal call sites are unchanged; `defdelegate` for any helper still needed through the public namespace; verify with `mix compile --warnings-as-errors`, `mix dialyzer --format short`, and full `mix test` after each extraction.

### Completed (see Changelog for details)

- `BDS.Generation` 2651 → 647 (76 %)
- `BDS.AI` 1711 → 168 (90 %)
- `BDS.Scripting.Capabilities` 1715 → 194 (89 %)
- `BDS.Posts` 1781 → 569 (68 %)
- `BDS.Desktop.ShellLive` 2607 → 1545 (41 %)

---

## 2. Process Dictionary for i18n State

**Status:** open. `Process.put(:bds_ui_locale, …)` + `Process.get(:bds_ui_locale)` in `render/1` of `BDS.Desktop.ShellLive` and every `*_editor.ex` (15 sites total).

**Why it matters:** implicit global state; complicates per-process isolation in tests and risks leaks between concurrent operations in the same process.

**Plan:** thread `locale` through `assigns`/render args; replace `translated/1,2` with a 3-arity helper that takes the locale explicitly; ban `Process.put` via Credo afterwards.

---

## 3. Side Effects in Transactions

**Status:** ✅ done in `BDS.Media` (2026-04-30). Open elsewhere — no audit yet for `BDS.Posts`, `BDS.Publishing`, `BDS.Generation`.

**Plan:** spot-check every `Repo.transaction/1` outside `BDS.Media`. Rule: only DB writes inside; filesystem and `Search.sync_*` after commit.

---

## 4. `String.to_atom/1` on Untrusted Input

**Status:** ✅ done. The only attacker-reachable site (`MCP.atomize_keys/1`) was deleted (2026-04-30). Nine remaining `String.to_atom/1` call sites all operate on bounded enums (workbench types, release platforms, route IDs, capability keys, AI catalog modalities) and are safe.

---

## 5. Bang File Operations in Long-Running Code

**Status:** open (limited scope).

**Scope:** only `File.read!`/`File.write!` reachable from a GenServer worker, scheduled task, or LiveView event matter. Mandatory-config reads at boot are fine.

**Plan:** sweep `BDS.Posts.RebuildFromFiles`, `BDS.Media`, `BDS.MCP`, `BDS.Generation`. Replace bang variants with `{:ok, _} | {:error, _}` propagation only on those paths.

---

## 6. Duplicate Helpers Across Contexts

**Status:** open.

**Duplicated functions (verified copy-pasted across `Posts`, `Media`, `Search`, `Generation`, `Publishing`, `MCP`):**

- `attr/2` (atom-or-string key access)
- `maybe_put/3`
- `blank_to_nil/1`
- `progress_callback/1`
- `report_rebuild_started/3`, `report_rebuild_progress/4`

**Plan:** consolidate into `BDS.MapUtils` (attr / maybe_put / blank_to_nil) and `BDS.ProgressReporter` (callback + reporters). Note: `Util` modules already exist inside `BDS.Generation`, `BDS.Scripting.Capabilities`, and `BDS.Posts.*`; the goal is one shared utility, not three more.

---

## 7. Direct `Repo.get` in `BDS.Desktop.ShellLive`

**Status:** open. 10 call sites verified.

**Plan:** add the missing context functions (`Posts.get_post_with_translations/1`, etc.) and replace each `Repo.get(Schema, id)` with the context call.

---

## 8. `String.to_existing_atom/1` + `rescue ArgumentError`

**Status:** open, low priority.

**Plan:** introduce explicit string→atom whitelists for the half-dozen call sites (`safe_existing_atom`, view-id parsing, panel-tab parsing) so the rescue clause becomes dead code, then delete it.

---

## 9. `Jason.decode!/1` on External HTTP Responses

**Status:** open.

**Scope:** only the 2 sites in `BDS.AI` / `BDS.AI.OpenAICompatibleRuntime` that decode HTTP response bodies. The remaining 12 `Jason.decode!/1` sites decode our own on-disk files (metadata, embeddings index, generation hashes) and are not in scope.

**Plan:** switch to `Jason.decode/1` and propagate `{:error, reason}` from the runtime through to the chat / one-shot orchestration layer in `BDS.AI.Chat` and `BDS.AI.OneShot`.

---

## 10. Missing `@spec`

**Status:** ✅ done for core contexts (2026-04-30). Open for LiveView editor modules and the smaller contexts (`Tags`, `Templates`, `Scripts`, `PostLinks`).

**Convention reminder:** Ecto schemas need explicit `@type t`; use `term()` for associations; use `@typedoc` + named types for repeated map shapes; for attrs maps use `%{optional(atom()) => term(), optional(String.t()) => term()}`.

---

## 11. Raw SQL Outside FTS5

**Status:** ✅ done for the `post_media` table (2026-04-30, replaced by `BDS.Posts.PostMedia` schema). Remaining raw SQL is FTS5-virtual-table queries in `BDS.Search` only — keep them raw.

---

## 12. Atom/String Key Duality

**Status:** open, low priority.

**Pattern:** `Map.get(assigns, :language, Map.get(assigns, "language", default))` in many editors and capability bridges.

**Plan:** normalize at boundaries. Adopt the rule "atoms internally, strings only at JSON/HTTP boundaries", and use `attr/2` (post-#6 consolidation) at every boundary point.

---

## 13. `BDS.Tasks` Memory Growth

**Status:** open, bounded in practice.

**Risk:** the `tasks` map grows for the lifetime of the BEAM unless the UI calls `clear_completed`/`clear_finished`. Long-running desktop sessions could accumulate thousands of finished tasks.

**Plan:** TTL eviction in the `BDS.Tasks` GenServer (e.g., drop `:completed`/`:failed`/`:cancelled` older than 1 h); already partially mitigated by `recent_finished_limit` in `build_status_snapshot/1`.

---

## 14. Synchronous Tests

**Status:** intentional, no further action.

Most tests share the SQLite repo and named GenServers (`BDS.Tasks`, `BDS.Search`, `BDS.AI.Catalog`, `BDS.Embeddings`). `async: false` is correct. Pure-logic tests (parsers, formatters) could opt into `async: true` opportunistically.

---

## What the Project Does Well

- Clear context separation (`Posts`, `Media`, `Projects`, `Search`, `AI`, `Generation`).
- Consistent Ecto changesets at every write boundary.
- Idiomatic `with` blocks for multi-step error flows.
- `Task.Supervisor` used correctly for background work.
- Submodule extraction pattern proven across 5 large modules without breaking public API contracts.

---

## Changelog

### 2026-05-01

- **God modules**:
  - `BDS.Scripting.Capabilities` 1715 → 194 (89 %). Submodules: `Util` (301), `Posts` (270), `Media` (254), `Crud` (284), `Projects` (204), `AppShell` (134), `Bridges` (176). Public `for_project/2` preserved.
  - Fixed real race in `test/bds/desktop/shell_live_test.exs:1149` (metadata-diff editor open) — was diagnosed as flake but was a missing `completed_task!(task.id)` synchronization between the worker `:DOWN` and the next `:refresh_task_status` tick.

### 2026-04-30

- **God modules**:
  - `BDS.AI` 1711 → 168 (90 %). Submodules: `Chat` (597), `OneShot` (382), `Catalog` (306), `ChatTools` (271), `Runtime` (100), `SettingsStore` (78). Public API preserved via `defdelegate`.
  - `BDS.Posts` 1781 → 569 (68 %). Submodules: `Slugs` (86), `AutoTranslation` (176), `FileSync` (146), `TranslationValidation` (464), `RebuildFromFiles` (320), `Translations` (279). Public API preserved via `defdelegate`.
  - `BDS.Generation` 2651 → 647 (76 %). Submodules: `Outputs` (490), `Validation` (445), `Data` (352), `Sitemap` (280), `Paths` (262), `Renderers` (227), `Progress` (96), `Pagefind` (70), `GeneratedFileHash` (23). `import only:` used to keep call sites unchanged.
  - `BDS.Desktop.ShellLive` 2607 → 1545 (41 %). Submodules: `TitlebarMenu`, `CliSync`, `PanelRenderer`, `TabHelpers`, `TaskLocalization`, `ChatSurface`, `SidebarCreate`, `Layout`, `ShellCommandRunner`, `SessionUtil`. Coordinator now holds only `mount/3`, `render/1`, `handle_event/3`, `handle_info/2`.
  - Side fix: `test/bds/maintenance_test.exs` had hardcoded `posts/2026/04/...` paths; added explicit `File.mkdir_p!` calls for the orphan-file fixtures.
- **Side effects in transactions** (`BDS.Media`): every `Repo.transaction/1` block in [lib/bds/media.ex](lib/bds/media.ex) refactored — DB writes inside, filesystem + `Search.sync_*` after commit. Functions touched: `import_media/1`, `update_media/2`, `upsert_media_translation/3`, `delete_media_translation/2`, `replace_media_file/2`, `link_media_to_post/2`, `unlink_media_from_post/2`. Spec correction: `delete_media_translation/2` returns `{:ok, boolean()} | {:error, …}`.
- **`String.to_atom` DoS**: `BDS.MCP.atomize_keys/1` deleted; the two `accept_proposal` sites pass string-keyed maps directly to `Media.update_media/2` and `Posts.update_post/2`, both of which already accept `%{optional(atom()) => term(), optional(String.t()) => term()}`.
- **Raw SQL on `post_media`**: introduced `BDS.Posts.PostMedia` schema with `unique_constraint([:post_id, :media_id])`; migrated 8 raw-query sites in `BDS.Media`, `BDS.Posts`, `BDS.Desktop.ShellLive.PostEditor`, `BDS.Desktop.ShellLive.OverlayComponents` to typed Ecto queries.
- **`@spec` for core contexts**: added specs and `@type t` to `BDS.Projects`, `BDS.Posts`, `BDS.Media`, `BDS.Search`, `BDS.Publishing`, `BDS.Generation`, `BDS.Metadata`, `BDS.MCP`, `BDS.AI` and their schemas. Bugs surfaced: `Search.list_stemmer_languages/0` return shape, `Media.sync_media_sidecar/1` returns `:ok`, `Media.replace_media_file/2` can return `{:ok, nil}`, removed unreachable fall-through clauses in `BDS.Posts` auto-translate cascades and `BDS.Desktop.ShellLive.ChatEditor.blank?/1`.

**Validation gate after every change:** `mix compile --warnings-as-errors` clean, `mix dialyzer --format short` 0 errors, `mix test` 342 tests / 0 failures / 4 skipped.
