# Elixir Code Smell Analysis — bDS2

Living document. Each section lists **status**, then **open work in priority order**, then a brief notes block. Completed work is listed compactly at the bottom (`## Changelog`).

Last refreshed: 2026-05-04.

---

## 1. God Modules

**Status:** in progress. Five originally-flagged god modules are reduced to coordinator size; eight new files (mostly LiveView editors) crossed the 800-line threshold and are now the active queue.

### Open queue (priority order)

| # | Module | Current lines | Target | Strategy |
|---|---|---|---|---|
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
- `BDS.Maintenance` 810 → 141 (83 %)
- `BDS.Media` 993 → 324 (67 %)
- `BDS.Desktop.ShellLive.ImportEditor` 1436 → 776 (46 %)
- `BDS.Rendering` 838 → 33 (96 %)

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

### 2026-05-04

- **God modules**:
  - `BDS.Rendering` 838 → 33 (96 %). Submodules under `lib/bds/rendering/`: `LinksAndLanguages` (131, canonical_post_path_by_slug + canonical_media_path_by_source_path + post_path/2,3 + link_contexts/4 + link_context + language_prefix + normalize_language), `TemplateSelection` (153, load_template_source + select_template + published_template_body + render_template + load_bundled_template_source + maybe_load_bundled_template_source + bundled_template_slug + template_render_context), `Metadata` (113, project_metadata + menu_items + to_template_menu_item + menu_item_href + blog_languages + tag_color_by_name + alternate_links + backlinks + default_pico_stylesheet_href + href_for_language + calendar_initial_year + calendar_initial_month), `PostRendering` (167, post_assigns + load_post_record + canonical_post_record + canonical_post_id + post_data_json + post_data_json_value + build_post_context + render_post_content), `ListArchive` (295, list_assigns + not_found_assigns + normalize_list_posts + normalize_pagination + normalize_archive_context + build_day_blocks + min_date + max_date + show_archive_range_heading? + calendar_initial_year_from_posts + calendar_initial_month_from_posts). Coordinator now contains only the 3 public renders (`render_post_page/3`, `render_list_page/2`, `render_not_found_page/1,2`) which delegate to `TemplateSelection.load_template_source`, `TemplateSelection.render_template`, and the appropriate assigns builder (`PostRendering.post_assigns`, `ListArchive.list_assigns`, `ListArchive.not_found_assigns`). Cross-submodule deps are linear: ListArchive → PostRendering + Metadata + TemplateSelection + LinksAndLanguages; PostRendering → Metadata + TemplateSelection + LinksAndLanguages; Metadata → LinksAndLanguages; TemplateSelection + LinksAndLanguages have no internal deps.

### 2026-05-03

- **God modules**:
  - `BDS.Desktop.ShellLive.ImportEditor` 1436 → 776 (46 %). Submodules under `lib/bds/desktop/shell_live/import_editor/`: `ConflictResolution` (50, change_conflict_resolution + update_conflict_resolution + update_conflict_bucket), `TaxonomyEditing` (206, start/cancel/save/clear_taxonomy_edit + analyze_taxonomy_ai + update_taxonomy_mapping + rebuild_taxonomy_stats + stat_key + apply_taxonomy_mappings + apply_taxonomy_mapping_bucket + existing_taxonomy_terms + normalize_taxonomy_mapping_value + auto_mapped_count + taxonomy_pill_class + taxonomy_item_editing? + taxonomy_mapping_tooltip + maybe_put_option), `AnalysisState` (248, change_definition + select_uploads_folder + select_and_analyze + note_analysis_progress + finish_analysis + handle_analysis_task_down + importable_counts + importable_entity_count + detail_items + default_analysis_state + default_sections + default_author + suggested_definition_name + maybe_put + allow_repo_sandbox + translate_phase), `ProgressTracking` (246, execute_import + note_execution_progress + finish_execution + handle_task_down + default_execution_state + execution_progress_width + decompose_progress_detail + to_string_or_nil + format_eta + translate_execution_phase). Components (`import_editor`, `conflict_section`, `post_detail_section`, `media_detail_section`, `stat_card`, `other_stat_card`, `media_stat_card`, `taxonomy_stat_card`, `taxonomy_group`) stay in main file (587 lines of HEEx); main also keeps `assign_socket/1`, `toggle_section/3`, `toggle_model_selector/2`, `select_ai_model/3`, and the small `selected_model`/`selected_model_label`/`preferred_model` helpers tied to `assign_socket`. Public API preserved via `defdelegate` for the 14 event handlers called from `BDS.Desktop.ShellLive`. ProgressTracking calls back into AnalysisState for `default_author/1`, `importable_counts/1`, `allow_repo_sandbox/1`, and the `:analysis` branch of `handle_task_down/6`. The 600-line target was not reachable while keeping all 9 components in the main file (components alone are 587 lines).

### 2026-05-02

### 2026-05-02

- **God modules**:
  - `BDS.Media` 993 → 324 (67 %). Submodules under `lib/bds/media/`: `FileOps` (150, attr/maybe_put/blank_to_nil/atomic_write/delete_file_if_present/list_matching_files/media_file_path/detect_mime/image_dimensions/image_mime?/progress callbacks), `Thumbnails` (165, thumbnail_paths/regenerate_thumbnails/regenerate_missing_thumbnails/ensure_thumbnails/delete_thumbnail_files + private render/write helpers), `Sidecars` (329, write_sidecar/write_translation_sidecar/parse_canonical_sidecar/parse_translation_sidecar/upsert_media_from_sidecar/upsert_translation_from_sidecar + sync/import-orphan public API + translation_sidecar_path/canonical_sidecar?/translation_sidecar?/binary_path_for_translation_sidecar/binary_exists_for_sidecar?), `Linking` (125, list_linked_posts/link_media_to_post/unlink_media_from_post/linked_post_ids), `Rebuilder` (82, rebuild_media_from_files/2). Public API preserved via `defdelegate`; coordinator keeps import_media/update_media/delete_media/upsert_media_translation/delete_media_translation/replace_media_file/list_media_translations and uses `import only:` for shared helpers.

### 2026-05-01

- **God modules**:
  - `BDS.Maintenance` 810 → 141 (83 %). Submodules under `lib/bds/maintenance/`: `Progress` (45), `FileScan` (158), `DiffComputation` (93), `DiffReports` (315), `Repair` (145). Coordinator keeps the 4 public entrypoints (`repair_metadata_diff/4`, `import_metadata_diff_orphans/3`, `rebuild_from_filesystem/3`, `metadata_diff/2`); submodules wired via `import only:`.
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
