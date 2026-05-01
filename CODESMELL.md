# Elixir Code Smell Analysis — bDS2

Living document. Each section lists **status**, then **open work in priority order**, then a brief notes block. Completed work is listed compactly at the bottom (`## Changelog`).

Last refreshed: 2026-05-09.

---

## 1. God Modules

**Status:** in progress. The originally-flagged god modules (now including `BDS.MCP`) are all reduced to coordinator size; the open queue is empty.

### Open queue (priority order)

_None._ All modules previously on the queue have been split; refresh the queue if a new module crosses the 800-line threshold.

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
- `BDS.Desktop.ShellLive.MenuEditor` 871 → 335 (62 %)
- `BDS.Desktop.ShellLive.PostEditor` 963 → 506 (47 %)
- `BDS.Desktop.ShellLive.SettingsEditor` 872 → 226 (74 %)
- `BDS.Desktop.ShellLive.ChatEditor` 972 → 576 (41 %)
- `BDS.MCP` 677 → 27 (96 %)

---

## 2. Process Dictionary for i18n State

**Status:** ✅ encapsulated (2026-05-10). Raw `Process.put(:bds_ui_locale, _)` / `Process.get(:bds_ui_locale)` no longer appears outside `BDS.Desktop.UILocale`. The two render boundaries (`BDS.Desktop.ShellLive.render/1` and `BDS.Desktop.ShellLive.SidebarComponents.sidebar_content/1`) now call `UILocale.put/1`; the ~30 helper read sites call `BDS.Desktop.UILocale.current/0`. The full thread-locale-through-assigns rewrite (~733 HEEx call sites) was rejected as too invasive for the marginal benefit; the encapsulation removes the implicit-global smell while keeping the LiveView lazy-render path intact.

**Why the helper does not restore on render exit:** Phoenix's `~H` returns a `Phoenix.LiveView.Rendered` whose `dynamic` function is invoked lazily by LiveView *after* `render/1` returns. A `try/after Process.delete` wrapper around `render/1` would clear the binding before child components materialize, so render boundaries use `UILocale.put/1` (set-only). `UILocale.with_locale/2` is provided for short-lived non-LiveView contexts (background tasks, scripts) that consume the binding eagerly inside the closure.

**Module rules:**

- Only `lib/bds/desktop/ui_locale.ex` may touch the `:bds_ui_locale` process key.
- New code that needs the active UI locale must call `BDS.Desktop.UILocale.current/0` (or take it as an argument).
- New render entry points that change the locale must call `BDS.Desktop.UILocale.put/1` at the top of `render/1`.

---

## 3. Side Effects in Transactions

**Status:** ✅ done for explicit `Repo.transaction/1` sites (2026-05-10). `BDS.Media`, `BDS.Templates.update_template/2`, `BDS.Metadata`, `BDS.Tags`, and `BDS.Projects` now keep filesystem/search/template-rebuild side effects outside their DB transactions. Remaining explicit transactions (`BDS.PostLinks`, `BDS.AI.Catalog`, project activation/deletion cleanup, and media link helpers) are DB-only or already run filesystem cleanup after commit. `BDS.Posts`, `BDS.Publishing`, and `BDS.Generation` do not currently use `Repo.transaction/1`.

**Rule:** only DB writes inside explicit transactions; filesystem, search sync, template rebuilds, and published-file rewrites run after commit.

---

## 4. `String.to_atom/1` on Untrusted Input

**Status:** ✅ done. The only attacker-reachable site (`MCP.atomize_keys/1`) was deleted (2026-04-30). Nine remaining `String.to_atom/1` call sites all operate on bounded enums (workbench types, release platforms, route IDs, capability keys, AI catalog modalities) and are safe.

---

## 5. Bang File Operations in Long-Running Code

**Status:** ✅ done (2026-05-10). Scoped `File.read!` / `File.write!` sites reachable from rebuild workers and LiveView events have been replaced with `{:ok, _} | {:error, _}` propagation.

**Scope audited:** `BDS.Posts.RebuildFromFiles`, `BDS.Media`, `BDS.MCP`, `BDS.Generation`, and the MCP settings UI config probe. Mandatory-config reads at boot remain out of scope.

**Rule:** long-running rebuild/sync/import paths and LiveView event-triggered config writes must not crash on expected filesystem read/write failures; return tagged errors instead.

---

## 6. Duplicate Helpers Across Contexts

**Status:** ✅ done (2026-05-10). Shared atom-or-string map helpers now live in `BDS.MapUtils`; shared two-arity progress callback extraction, count-based progress math, message shaping, scaling, phase reporting, and rebuild wrappers now live in `BDS.ProgressReporter`.

**Scope closed:** `Posts`, `Media`, `Search`, `Generation`, `Publishing`, `MCP`, plus the same rebuild helper copies in `Scripts`, `Templates`, and `Embeddings`. Domain modules may keep thin wrappers for readability, but progress behavior is parameterized through the shared reporter. Remaining helpers with similar names are intentionally different local UI/import trimming helpers or non-progress map utilities.

---

## 7. Direct `Repo.get` in `BDS.Desktop.ShellLive`

**Status:** ✅ done (2026-05-01). `Repo.get/2` and `Repo.get!/2` no longer appear in `BDS.Desktop.ShellLive` or its submodules. ShellLive entity reads now go through context APIs (`Posts.get_post/1`, `Posts.get_post!/1`, `Media.get_media/1`, `Templates.get_template/1`, `Scripts.get_script/1`, `AI.get_chat_conversation/1`, and `Settings.get_global_setting/1` / `put_global_setting/2`). Added a regression test that scans ShellLive source for direct `Repo.get` calls.

**Rule:** ShellLive modules may use `Repo` for query-shaped read models where no context abstraction exists yet, but direct primary-key entity fetches belong in context modules.

---

## 8. `String.to_existing_atom/1` + `rescue ArgumentError`

**Status:** ✅ done (2026-05-01). `String.to_existing_atom/1` call sites were replaced with explicit string→atom whitelists in `BDS.BoundedAtoms`. Session restore, LiveView view/tab/route parsing, panel tab parsing, shell command parsing, import sections, taxonomy types, AI endpoints, MCP agents, menu kinds, script kinds, and post/translation status parsing now all use bounded parsers with explicit fallbacks.

**Rule:** user/client/file-provided strings must not be converted with `String.to_existing_atom/1` plus rescue; add a bounded parser for the relevant enum instead.

---

## 9. `Jason.decode!/1` on External HTTP Responses

**Status:** ✅ done (2026-05-01). The 2 scoped HTTP response decodes in `BDS.AI.OpenAICompatibleRuntime` now use `Jason.decode/1` and return `{:error, %{kind: :invalid_json_response, reason: reason}}` for malformed model-list or chat-completion response bodies. The error shape propagates through endpoint model listing, chat, and one-shot orchestration via the existing `with` chains. Remaining `Jason.decode!/1` sites in `BDS.AI.Catalog` decode model-catalog HTTP/cache payloads or trusted on-disk JSON and are out of scope for this section.

**Rule:** OpenAI-compatible runtime HTTP responses must not be decoded with bang functions; malformed provider JSON is a recoverable runtime error.

---

## 10. Missing `@spec`

**Status:** ✅ done (2026-05-01). Core contexts, LiveView editor modules, and the smaller contexts (`Tags`, `Templates`, `Scripts`, `PostLinks`) now have public `@spec` coverage. `BDS.SpecCoverageTest` scans the Section 10 module set and fails when a public function/arity lacks a matching spec.

**Convention reminder:** Ecto schemas need explicit `@type t`; use `term()` for associations; use `@typedoc` + named types for repeated map shapes; for attrs maps use `%{optional(atom()) => term(), optional(String.t()) => term()}`.

---

## 11. Raw SQL Outside FTS5

**Status:** ✅ done for the `post_media` table (2026-04-30, replaced by `BDS.Posts.PostMedia` schema). Remaining raw SQL is FTS5-virtual-table queries in `BDS.Search` only — keep them raw.

---

## 12. Atom/String Key Duality

**Status:** ✅ done (2026-05-01). Same-name atom/string boundary reads now use `BDS.MapUtils.attr/2` or `attr/3` instead of nested `Map.get/3` or `Map.get/2 || Map.get/2` fallbacks. The cleanup covers AI endpoint/chat/one-shot attrs, model capabilities, rendering assigns and list pagination/archive contexts, UI shortcut/filter params, metadata category settings, metadata-diff repair payloads, CLI sync payloads, chat tool calls, and duplicate/metadata-diff editor payloads.

**Rule:** atoms internally, strings only at JSON/HTTP/form/render boundaries. If a boundary must accept both atom and string keys for the same snake_case field, use `BDS.MapUtils.attr/2` or `attr/3`; do not open-code same-name dual-key reads.

---

## 13. `BDS.Tasks` Memory Growth

**Status:** ✅ done (2026-05-01). `BDS.Tasks` now evicts terminal tasks (`:completed`/`:failed`/`:cancelled`) after a configurable TTL (`:finished_task_ttl_ms`, default 1 h). Eviction is triggered by the GenServer after a task finishes and also pruned on read calls (`get_task`, `status_snapshot`, `list_tasks`, `list_running_tasks`), while pending/running tasks remain retained. The UI snapshot still separately limits recently finished entries with `recent_finished_limit`.

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

- **Missing `@spec`**: closed Section 10 by adding public specs to the remaining smaller contexts (`BDS.Tags`, `BDS.Templates`, `BDS.Scripts`, `BDS.PostLinks`) and LiveView editor modules under `BDS.Desktop.ShellLive.*Editor`. Added `BDS.Tags.Tag.t/0` to match the existing schema typing convention and introduced `BDS.SpecCoverageTest`, which scans the Section 10 module set for public function/arity entries without matching specs.

- **`BDS.Tasks` memory growth**: added configurable TTL eviction for terminal tasks in the `BDS.Tasks` GenServer (`:finished_task_ttl_ms`, default 1 h). Finished tasks are pruned by delayed GenServer cleanup and on task read calls; active tasks are preserved. Added regression coverage that completes a task with a tiny TTL and verifies it disappears without `clear_finished/0` while a running task remains. Section 13 is closed.

- **Atom/string key duality**: added `BDS.MapUtils.attr/3` and a regression test that scans `lib/**/*.ex` and `lib/**/*.heex` for same-name atom/string `Map.get` fallback reads. Replaced same-name atom/string boundary reads across AI attrs, rendering assigns, pagination/archive contexts, UI command/filter params, metadata category settings, metadata-diff repair payloads, CLI sync payloads, chat tool call normalization, and misc editor duplicate/metadata-diff payload rendering. Remaining mixed-key scan hits are intentionally different-key fallbacks (for example camelCase/snake_case JSON compatibility) or atom-only/string-only boundaries. Section 12 is closed.

- **`Jason.decode!/1` on external HTTP responses**: replaced the 2 scoped OpenAI-compatible runtime response decodes with `Jason.decode/1` and tagged `{:error, %{kind: :invalid_json_response, reason: reason}}` propagation for malformed `/models` and `/chat/completions` bodies. Added regressions covering endpoint model listing through a fake HTTP client and generation through a local Bandit server. Section 9 is closed.

### 2026-05-10

- **Duplicate helpers across contexts**: added `BDS.MapUtils` (`attr/2`, `maybe_put/3`, `blank_to_nil/1`) and expanded `BDS.ProgressReporter` (`callback/1`, `scaled/3`, `report_count_started/4`, `report_count_progress/5`, `report_rebuild_started/3`, `report_rebuild_progress/4`, `report_phase/3`). Replaced copy-pasted helpers in posts, post translations, post rebuild, media file ops, search, generation progress, maintenance progress, embeddings/index progress, publishing, MCP util, scripts, and templates. Domain-specific modules now express their wording/ranges as options to the shared reporter, preserving existing user-facing progress messages while sharing one implementation. Added focused tests for both shared modules. Section 6 is closed.

- **Bang file operations in long-running code**: `BDS.Media.Sidecars.parse_canonical_sidecar/2` and `parse_translation_sidecar/1` now use `File.read/1` and return `{:ok, sidecar}` or `{:error, {:read_sidecar, path, reason}}` instead of raising. Media rebuild collects parsed sidecars and returns the first sidecar read error before mutating rows; media sync/import sidecar entrypoints propagate the same errors. Added regression coverage for an unreadable `.meta` sidecar directory preserving the worker instead of crashing it.
- **Bang file operations in long-running code**: `BDS.Posts.RebuildFromFiles.parse_rebuild_file/2` now uses `File.read/1` and returns `{:ok, rebuild_file}` or `{:error, {:read_rebuild_file, path, reason}}`; post rebuild/import/sync-from-file callers propagate the tagged error. `BDS.Generation.apply_validation/2` now hashes existing generated files with `File.read/1` and returns `{:error, {:read_generated_file, path, reason}}` on read failures. `BDS.MCP.AgentConfig` now uses `File.mkdir_p/1`, `File.read/1`, `Jason.decode/1`, and `File.write/2`, returning tagged config read/write/create/decode errors instead of raising; the settings editor reports those errors through its existing output surface and its config probe no longer uses bang reads. Added regressions for unreadable post files, unreadable generated files, unreadable MCP config, and unwritable MCP config. Section 5 is closed.

- **Side effects in transactions**: `BDS.Metadata.update_project_metadata/2`, `sync_project_metadata_from_filesystem/1`, and the shared category/publishing `update_state` path now keep only project/settings row changes inside `Repo.transaction/1`. Metadata JSON files are flushed after commit and `Persistence.atomic_write/2` now returns `{:error, reason}` for directory-creation failures instead of raising. Added regression coverage for a failed metadata filesystem flush preserving the committed project/settings changes.
- **Side effects in transactions**: `BDS.Tags.sync_tags_from_posts/1`, `delete_tag/1`, `rename_tag/2`, and `merge_tags/2` now commit tag/post-tag DB changes before published-post rewrites and `meta/tags.json` flushes. `BDS.Projects.ensure_default_project/0` and `create_project/1` now commit the project row before rebuilding templates from filesystem files. Added regressions for failed tag JSON flushes and failed template rebuilds preserving committed DB changes. Finished the explicit `Repo.transaction/1` audit: remaining transactions are DB-only or already defer filesystem cleanup until after commit; `BDS.Posts`, `BDS.Publishing`, and `BDS.Generation` have no explicit transaction sites.
- **Process dictionary for i18n state (Section 2)**: encapsulated behind `BDS.Desktop.UILocale` (`lib/bds/desktop/ui_locale.ex`, ~50 lines). Public surface: `put/1` (set without restore, for LV render boundaries that return lazy `Rendered`), `with_locale/2` (set + try/after restore, for short-lived eager contexts), `current/0` (read, returns `nil` when unset). The two raw `Process.put(:bds_ui_locale, _)` sites (`BDS.Desktop.ShellLive.render/1` and `BDS.Desktop.ShellLive.SidebarComponents.sidebar_content/1`) now call `UILocale.put/1`; the ~30 raw `Process.get(:bds_ui_locale)` reads (every editor `translated/1,2` helper plus `BDS.Desktop.ShellData.effective_ui_language/1`) now call `BDS.Desktop.UILocale.current/0`. The full thread-locale-through-assigns rewrite (~733 HEEx call sites) was deliberately rejected as too invasive; the encapsulation removes the implicit-global smell while preserving Phoenix's lazy `Rendered` evaluation. The render path uses `put/1` (not `with_locale/2`) because Phoenix `~H` returns a `Rendered` whose `dynamic` is invoked by LiveView *after* `render/1` returns; a `try/after Process.delete` would clear the binding before child components materialize. Only `BDS.Desktop.UILocale` is allowed to touch the `:bds_ui_locale` process key. Validates clean: `mix compile --warnings-as-errors`, `mix dialyzer --format short` (Total errors: 0), `mix test` (342 tests, 0 failures, 4 skipped, three consecutive runs).

### 2026-05-09

- **God modules**:
  - `BDS.MCP` 677 → 27 (96 %). Submodules under `lib/bds/mcp/`: `Util` (36, sanitize/1 + normalize_term/1 + maybe_put/3 + map_get/3), `Queries` (201, page_size/0 + active_project!/0 + post_summary/1 + post_detail/1 + translated_post_detail/2 + search_filters/1 + parse_status/1 + group_rows/2 + private group_values/2 (5 clauses) + available_languages/2 + linked_posts/2 + private load_linked_post/1 + post_body/1 + translation_body/1 + tag_post_count/2 + category_post_count/2), `Tools` (394, list/0 + call/2 + validate_template/1 + private check_term/1 + search_posts/1 + count_posts/1 + read_post_by_slug/1 + draft_post/1 + propose_script/1 + propose_template/1 + propose_media_metadata/1 + propose_post_metadata/1 + accept_proposal/1 + discard_proposal/1 + script_validation/1 + parse_script_kind/1 + parse_template_kind/1 + tool/2), `Resources` (112, list/0 + read/1 + private posts_resource/1 + media_resource/1 + tags_resource/0 + categories_resource/0 + read_post_resource/1 + read_media_resource/1). Coordinator `BDS.MCP` keeps the 5 public entrypoints (`list_tools/0`, `list_resources/0`, `call_tool/2`, `read_resource/1`, `validate_template/1`) as `defdelegate` to `Tools`/`Resources` and re-exports the `tool_descriptor`/`resource_descriptor` types as aliases of `Tools.descriptor`/`Resources.descriptor`. Cross-submodule deps are linear and acyclic: `Tools` → `Queries` + `Util` + `ProposalStore`; `Resources` → `Queries` + `Util` + `ProposalStore`; `Queries` → `Util`; `Util` is a leaf. Existing siblings (`ProposalStore`, `Proposal`, `AgentConfig`, `Server`, `Stdio`) untouched. The pre-existing `BDS.MCP.Server`/`Stdio` callers (`call_tool` / `list_tools` / `list_resources` / `read_resource`) keep using the coordinator unchanged. Validates clean: `mix compile --warnings-as-errors`, `mix dialyzer --format short` (Total errors: 0), `mix test` (342 tests, 0 failures, 4 skipped).

### 2026-05-08

- **God modules**:
  - `BDS.Desktop.ShellLive.ChatEditor` 972 → 576 (41 %). Submodules under `lib/bds/desktop/shell_live/chat_editor/`: `ToolSurfaces` (274, build_render_surfaces + build_render_surface + do_build_render_surface (8 clauses) + build_tab_surface + decode_surface_actions/options + normalize_tool_surface + map_value + numeric_value + stringify_list + render_tool? + @render_tool_names), `ToolTracking` (101, tool_call_name + tool_call_arguments + normalize_tool_calls + tool_arguments_preview + mark_tool_call_completed + tool_markers_from_events + mark_last_matching_complete + preview_value + @tool_args_max_length), `MessageBuild` (118, build/1,2 + build_entries + finalize_entry + start_entry + append_tool_surface + pending_user_message + streaming_content), `ModelSelection` (80, toggle_model_selector + set_model + group_available_models + needs_api_key? + provider_group_label + blank?). Coordinator keeps the 3 HEEx components (chat_editor, chat_tool_markers, chat_surface), the 13 public event handlers (assign_socket, update_input, update_surface_form, select_surface_tab, current_surface_data, set_action_error, clear_action_error, send_message, abort_message, note_tool_call, note_tool_result, note_streaming_content, finish_request), the HEEx-callable helpers (markdown_html, message_role_label, payload_json, chart_width, truthy?, tool_surface_type, translated/1,2), private helpers (update_request, allow_repo_sandbox, rewrite_external_images, external_image_link, surface_input_type, present?, format_error), and `defdelegate` entries for `build/1`, `toggle_model_selector/2`, `set_model/4`, `tool_call_name/1`, `tool_call_arguments/1`. Cross-submodule deps are linear: MessageBuild → ModelSelection + ToolSurfaces + ToolTracking; ToolSurfaces, ToolTracking, ModelSelection are leaves. Each submodule that needs it duplicates the small `translated/2` and `blank?/1` helpers locally per the established convention; ToolSurfaces also duplicates `truthy?/1` privately. ModelSelection uses `Phoenix.Component.assign/3` via `import only:`. The 400-line target was not reachable while keeping all 3 HEEx components in the coordinator (the chat_surface component alone is ~200 lines). Validates clean: `mix compile --warnings-as-errors`, `mix dialyzer --format short` (Total errors: 0), `mix test` (342 tests, 0 failures, 4 skipped).

### 2026-05-07

- **God modules**:
  - `BDS.Desktop.ShellLive.SettingsEditor` 872 → 226 (74 %). Submodules under `lib/bds/desktop/shell_live/settings_editor/`: `StyleEditor` (103, build_style + select_style_theme + change_style_preview_mode + apply_style_theme + theme_display_name + current_theme + style_theme + @themes), `MCPConfig` (100, mcp_rows + toggle_mcp_agent + find_mcp_agent + mcp_configured? + mcp_config_path + mcp_server_present? + @mcp_agents), `PublishingSettings` (89, publishing_form + update_publishing_draft + save_publishing + clear_publishing + publishing_attrs + normalize_publishing_params), `EditorSettings` (93, editor_form + update_editor_draft + save_editor + get_global_setting + put_global_setting + editor_attrs + normalize_editor_params + boolean_string), `ProjectSettings` (112, project_metadata + project_form + technology_form + update_project_draft + save_project + project_attrs + normalize_project_params), `ManagedCategories` (194, protected_categories + protected_category? + category_rows + update_new_category + add_category + reset_categories + save_category + remove_category + ensure_default_categories + reset_default_category_settings + @protected_categories + @default_category_settings), `AISettings` (203, ai_form + endpoint_model_options + update_ai_draft + refresh_ai_models + save_ai + reset_ai_prompt + ai_attrs + normalize_ai_params + get_model_preference + maybe_put_model_preference + put_endpoint_preferences + endpoint_refresh_attrs + normalize_endpoint_result). Coordinator keeps `embed_templates "settings_editor_html/*"` (HEEx components `settings_editor` + `style_editor`), `assign_socket/1`, `update_search/3`, the `build_settings/1` aggregator, the `current_settings_section`/`current_tab_meta`/`visible_settings_sections`/`section_matches?`/`template_options` helpers, the `translated/1,2` HEEx render-time helper, and `defdelegate` entries for the 21 public event handlers + the HEEx-callable `theme_display_name/1` (delegated to `StyleEditor`) and `protected_category?/1` (delegated to `ManagedCategories`). Cross-submodule deps: `AISettings` calls `EditorSettings.{get_global_setting/1, put_global_setting/2}` (the only intra-submodule dependency); all other submodules are leaves. Each submodule duplicates the small `translated/2`, `truthy?/1`, `blank_to_nil/1`, `parse_integer/2`, `boolean_string/1` helpers locally per the established convention. Submodules use `Phoenix.Component.assign/3` directly via `use Phoenix.Component`. Validates clean: `mix compile --warnings-as-errors`, `mix dialyzer --format short` (Total errors: 0), `mix test` (342 tests, 0 failures, 4 skipped).

### 2026-05-06

- **God modules**:
  - `BDS.Desktop.ShellLive.PostEditor` 963 → 506 (47 %). Submodules under `lib/bds/desktop/shell_live/post_editor/`: `PostMetadata` (190, project_metadata + canonical_language + translations + languages + template_options + linked_media + post_links + translation_flags + footer + format_timestamp + display_title + gallery_count + preview_url + canonical_preview_path + pad2 + maybe_put_query + truthy? + blank? + blank_to_nil), `ListValues` (125, field_key + tag_values/category_values + tag_suggestions/category_suggestions + filter_suggestions + tag_chips + query_addable? + normalize_query + normalize_list_entry + ensure_list_value + csv_to_list + tag_chip_style + normalize_color + contrast_color + ai_overlay_fields), `DraftManagement` (183, normalize_mode + normalize_language + normalize_params + current_draft + persisted_form/3,4 + maybe_update_draft + put_draft_field + put_query_state + query_value + query_key + maybe_drop_old_language_draft + toggled_sections + put_nested_map + delete_nested_map + reload_with_assigned_workbench + save_state_for_action + record_title + record_status + editing_canonical_language?), `Persistence` (105, persist + discard + has_published_version? + discard_label + discard_title + save_canonical_draft + save_translation_draft + maybe_publish_post + maybe_publish_translation). Coordinator keeps the 16 public event handlers (assign_socket, update, persist_socket, discard_socket, delete_socket, set_mode, toggle_section, select_language, toggle_quick_actions, detect_language, translate, apply_ai_suggestions, insert_content, add_list_value, remove_list_value), build/1,2, and the HEEx-callable helpers (`translated/1,2`, `post_status_label/1`, `post_editor_save_state_label/1`, `post_editor_mode_label/1`); `tag_chip_style/1` is exposed via `defdelegate` so HEEx call sites stay unchanged. Cross-submodule deps form a runtime cycle between PostMetadata.canonical_language → DraftManagement.normalize_language and DraftManagement.persisted_form → PostMetadata.translations/canonical_language (compile-safe, no compile cycle). Persistence → DraftManagement + PostMetadata; ListValues is a leaf. Each submodule that needs it duplicates the small `translated/2`, `blank_to_nil/1`, `csv_to_list/1` helpers locally per the established convention. Submodules use `Phoenix.Component.assign/3` directly (only DraftManagement needs it). The 400-line target was not reachable while keeping all 16 public event handlers + build + HEEx helpers in the coordinator. Validates clean: `mix compile --warnings-as-errors`, `mix dialyzer --format short` (0 errors), `mix test` (342 tests, 0 failures, 4 skipped).

### 2026-05-05

- **God modules**:
  - `BDS.Desktop.ShellLive.MenuEditor` 871 → 335 (62 %). Submodules under `lib/bds/desktop/shell_live/menu_editor/`: `TreeOps` (296, home_item/home_item_id + ui_item + persisted_item + first_item_id + insert_target + path_prefix? + find_path + item_at_path + items_at_path + replace_items_at_path + update_item + insert_item + remove_item + remove_item_with_value + append_child + move_selected + indent_selected + unindent_selected + delete_selected + drop_selected + insert_dropped_item), `TreePredicates` (55, can_move_up?/can_move_down?/can_indent?/can_unindent?/can_delete? + draft_item?), `DraftManagement` (132, current_draft + start_page_draft + start_category_draft + finalize_submenu_draft + assign_page_to_draft + assign_category_to_draft + cancel_draft + confirm_category_draft), `PageCategory` (58, page_posts + page_post + filter_page_posts + category_options + filter_categories + blank_to_nil), `State` (85, ensure_state + update_state + build + save + load_state). Coordinator keeps the 11 public event handlers (assign_socket, select_item, change_entry, submit_entry, cancel_entry, select_page, select_category, toolbar_action, drop_item, handle_keydown), the 3 HEEx components (menu_editor, menu_tree_level, kind_icon), and the render-time helpers (translated, row_label, kind_label, editing_title/hint/placeholder); `draft_item?/2` is exposed via `defdelegate` so HEEx call sites stay unchanged. Cross-submodule deps are linear: State → PageCategory + TreeOps + TreePredicates; DraftManagement → PageCategory + TreeOps; TreePredicates → TreeOps; PageCategory and TreeOps are leaves. `confirm_category_draft/2` takes the State.update_state function as an argument to avoid a cycle. Validates clean: `mix compile --warnings-as-errors`, `mix dialyzer --format short` (0 errors), `mix test` (342 tests, 0 failures, 4 skipped).

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

- **`String.to_existing_atom/1` + rescue**: added `BDS.BoundedAtoms` as the shared bounded string→atom parser for sidebar views, editor routes, panel tabs, post statuses, translation statuses, script/template/menu kinds, import sections, taxonomy types, AI endpoints, MCP agents, and shell commands. Replaced every `String.to_existing_atom/1` call site and removed the `safe_existing_atom` rescue helpers. Added regression coverage that scans `lib/**/*.ex` to prevent reintroducing `String.to_existing_atom/1` outside the bounded parser module. Section 8 is closed.

- **Direct `Repo.get` in `BDS.Desktop.ShellLive`**: added context helpers for primary-key reads (`Posts.get_post/1`, `Media.get_media/1`, `Templates.get_template/1`, `Scripts.get_script/1`, `AI.get_chat_conversation/1`) and introduced `BDS.Settings` for global editor settings. Replaced all ShellLive `Repo.get/2` and `Repo.get!/2` calls across the main shell, tab helpers, CLI sync, panel renderer, chat message build, code entity editor, post editor, media editor, overlay components, post metadata, and settings editor. Added a ShellLive regression test that scans source files to keep direct `Repo.get` calls out. Section 7 is closed.

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
