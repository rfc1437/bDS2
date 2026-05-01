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

### 2026-05-10

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
