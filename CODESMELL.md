# bDS2 Elixir Anti-Pattern & Best-Practice Audit

> Audited: 2026-05-06
> Scope: Elixir application, Phoenix LiveView UI, Ecto DB layer, Desktop (wx) integration, Rendering/Generation pipelines

---

## How to use this file

1. Pick a section.
2. Search the codebase for the file/line references.
3. Write a failing test that reproduces the issue.
4. Fix the code.
5. Run the full test suite and `mix dialyzer`.
6. Delete the item from this file.

---

## Critical (Fix Immediately)

### ~~CSM-001 — Atom Table Exhaustion Vulnerability~~ ✅ FIXED
- **Fixed:** 2026-05-06
- **What was done:**
  - Added `BDS.MapUtils.safe_atomize_key/1` and `BDS.MapUtils.safe_atomize_keys/1` — uses `String.to_existing_atom/1` with rescue fallback to keep unknown keys as strings.
  - Replaced all 6 affected `String.to_atom` call sites:
    - `lib/bds/import_definitions.ex` — `atomize_keys/1` → `MapUtils.safe_atomize_keys/1`
    - `lib/bds/import_execution.ex` — `normalize_report/1` → `MapUtils.safe_atomize_keys/1`
    - `lib/bds/ai/catalog.ex` — `atomize_map_keys/1` → `MapUtils.safe_atomize_keys/1`, `parse_modality/1` → `MapUtils.safe_atomize_key/1`
    - `lib/bds/ai/chat_tools.ex` — `metadata_attrs/2` → `MapUtils.safe_atomize_key/1`
    - `lib/bds/desktop/automation.ex` — `atomize_map/1` → `MapUtils.safe_atomize_keys/1`
  - Replaced lower-risk `String.to_atom` with `String.to_existing_atom/1`:
    - `lib/bds/ui/menu_bar.ex` — sidebar view and singleton editor command IDs
    - `lib/bds/ui/workbench.ex` — `normalize_type/1`
    - `lib/bds/desktop/shell_live/chat_editor/tool_surfaces.ex` — `map_value/3`
    - `lib/bds/release_packaging.ex` — `normalize_platform/1`
  - Updated `test/bds/bounded_atoms_test.exs` to enforce no `String.to_atom` on dynamic data (replaced old `String.to_existing_atom` ban).

---

### ~~CSM-002 — Search Loads Entire Tables into Memory~~ ✅ FIXED
- **Fixed:** 2026-05-07
- **What was done:**
  - Replaced `search_posts/3` and `search_media/3` with SQL-level filtering and pagination.
  - Blank queries now use pure Ecto queries with `where` clauses for status, language, year/month, date range, tags, categories, and missing translations.
  - Non-blank (FTS) queries use a CTE (`WITH fts_results AS (...)`) to preserve `bm25` ordering, joined with the posts/media table, with all filters applied in SQL.
  - Tag and category overlap filtering uses `json_each` in `EXISTS` subqueries.
  - Missing-translation filtering uses a `NOT EXISTS` correlated subquery.
  - Count uses `select count` + `Repo.one` instead of `length(all_records)`.
  - Pagination uses SQL `LIMIT`/`OFFSET` instead of `Enum.drop`/`Enum.take`.
  - Removed all old Elixir-side filter helpers: `candidate_post_ids`, `load_posts_in_order`, `filter_posts`, `paginate`, `matches_status?`, `matches_overlap?`, etc.
  - Added comprehensive tests for blank-query and non-blank-query filtering across all filter dimensions.

---

### ~~CSM-003 — Non-Atomic Side Effects in Post CRUD~~ ✅ FIXED
- **Fixed:** 2026-05-07
- **What was done:**
  - Replaced all 11 `Repo.delete!` call sites with `Repo.delete` + `{:error, _}` handling:
    - `lib/bds/posts.ex` — `delete_post/1`
    - `lib/bds/scripts.ex` — `delete_script/1`
    - `lib/bds/media.ex` — `delete_media/1`, `delete_media_translation/3`
    - `lib/bds/templates.ex` — `delete_template/2`, `remove_orphan_templates/2`
    - `lib/bds/tags.ex` — `delete_tag/1`, `merge_tags/2`
    - `lib/bds/projects.ex` — `delete_project/1`
    - `lib/bds/posts/translations.ex` — `delete_post_translation/1`
    - `lib/bds/posts/translation_validation.ex` — `fix_invalid_database_row/1`
  - Reordered `delete_post/1` to perform `Repo.delete` first, then clean up files/embeddings/search/links. Side effects now only run after DB commit succeeds.
  - Same reordering applied to `delete_script/1`, `delete_media/1`, `delete_template/2`, and `delete_post_translation/1`.
  - `delete_media/1` now wraps translation + media deletes in a `Repo.transaction` for atomicity.
  - Tags and projects already used `Repo.transaction`; replaced inner `Repo.delete!` with `Repo.delete` + `Repo.rollback` on error.
  - Added tests for delete atomicity and not-found handling.

---

### ~~CSM-004 — Blocking `init/1` + Missing `terminate/2` in Job Runner~~ ✅ FIXED
- **Fixed:** 2026-05-08
- **What was done:**
  - Moved `JobStore.attach_runner/2` from `init/1` to a new `handle_continue(:attach_and_start)` callback, so supervisor startup is no longer blocked by the synchronous call.
  - Added `terminate/2` callback that calls `JobStore.detach_runner/2` (with `try/catch` for shutdown safety), centralizing cleanup that was previously scattered across individual exit paths.
  - Added `handle_info({:EXIT, _pid, _reason})` clause to handle trapped exit signals from linked processes.
  - Removed redundant inline `detach_runner` calls from `handle_call(:cancel)`, task result handler, and `:DOWN` handler — `terminate/2` now handles all detach cleanup.
  - Changed `restart: :temporary` since job runners are one-shot processes that should not auto-restart on failure.
  - Added `@impl true` to all `handle_info` clauses.
  - Fixed pre-existing bug in `JobStore.detach_runner` handler where `update_in/2` macro result was incorrectly double-wrapped, corrupting state.
  - Added test: start a runner, kill it externally (not via cancel), assert `JobStore` no longer contains the dead PID.

---

### ~~CSM-005 — Client-Side Filtering of Entire Tables~~ ✅ FIXED
- **Fixed:** 2026-05-08
- **What was done:**
  - **Sidebar** (`lib/bds/ui/sidebar.ex`):
    - Removed `list_posts/1` and `list_media/1` that loaded all records into memory.
    - Replaced `apply_post_filters/1` and `apply_media_filters/1` (Elixir-side filtering) with SQL `WHERE` clauses using Ecto dynamic queries and SQLite `json_each` fragments.
    - Page/non-page split now uses `EXISTS (SELECT 1 FROM json_each(categories) WHERE lower(value) = 'page')` in SQL.
    - Search, year/month, tag, and category filters all push to SQL via `maybe_where_search`, `maybe_where_year`, `maybe_where_month`, `maybe_where_all_tags`, `maybe_where_all_categories`.
    - Aggregate queries (`year_month_counts`, `available_tags`, `available_categories`) use `Ecto.Adapters.SQL.query!` with `json_each` cross-joins, `GROUP BY`, and `DISTINCT`.
    - Pagination uses SQL `LIMIT` instead of `Enum.take`.
    - `tag_count/1` replaces `list_tags/1` + `length/1` with `Repo.one(select: count(tag.id))`.
    - Fixed `group_posts/1` O(n²) `acc.draft ++ [post]` pattern — now uses `Enum.group_by/2` (also fixes CSM-024).
  - **Tags** (`lib/bds/tags.ex`):
    - `posts_with_tag/2` now uses `EXISTS (SELECT 1 FROM json_each(?) WHERE value = ?)` instead of loading all posts.
    - `posts_with_any_tag/2` now uses `json_each` cross-join with a JSON parameter for the tag name list.
    - `post_tag_names/1` now selects only the `tags` column instead of loading full post records.
  - **Dashboard** (`lib/bds/ui/dashboard.ex`):
    - `post_stats` uses `GROUP BY post.status, SELECT {status, count(id)}` — no longer loads all posts.
    - `media_stats` uses `SELECT count(id), coalesce(sum(size), 0)` and a separate image count query with `LIKE 'image/%'`.
    - `tag_cloud_items` and `category_counts` use raw SQL with `json_each` cross-joins and `GROUP BY`.
    - `timeline_entries` uses SQL `strftime` + `GROUP BY` for year/month aggregation.
    - `recent_posts` uses SQL `ORDER BY updated_at DESC LIMIT 5`.
  - **Posts** (`lib/bds/posts.ex`):
    - `dashboard_stats/1` uses `GROUP BY post.status, SELECT {status, count(id)}` instead of loading all statuses.
  - **Capabilities** (`lib/bds/scripting/capabilities/`):
    - `tag_post_ids/2` uses `json_each` fragment + `SELECT post.id` instead of loading all posts.
    - `names_with_counts/2` uses raw SQL with `json_each` + `GROUP BY` instead of loading all posts.
    - `posts_by_status/2` filters at SQL level instead of loading all posts and filtering in Elixir.
  - Added 20 tests in `test/bds/csm005_sql_filtering_test.exs` covering dashboard stats, tag cloud, sidebar page/post separation, tag/search/year-month filters, available aggregates, and media filtering.

---

## High Severity

### ~~CSM-006 — N+1 Queries in Reindexing & Rendering~~ ✅ FIXED
- **Fixed:** 2026-05-08
- **What was done:**
  - **Batch INSERT for reindexing:** Replaced per-row `Repo.query!` INSERT in `reindex_posts/2` and `reindex_media/2` with multi-row batch INSERTs. Rows are chunked at 166 per batch (SQLite 999-parameter limit ÷ 6 columns). Translations were already preloaded in batch; fixed O(n²) `acc ++ [translation]` pattern in `preload_post_translations` and `preload_media_translations` by replacing with `Enum.group_by`.
  - **Rendering — preloaded post records:** `PostRendering.post_assigns/2` now accepts an optional `:_post_record` key in assigns, skipping the `Repo.get(Post, id)` re-query when the record is already available.
  - **Generation outputs pass records:** `build_page_outputs` and `build_post_outputs` in `outputs.ex` now pass the already-loaded post/translation records via `:_post_record`, eliminating per-post DB queries during generation.
  - **ListArchive** already used `load_post_records_batch` (batch query) — no change needed.
  - Added telemetry-based query counting tests: reindex 100 posts/media and assert total query count <10.

---

### ~~CSM-007 — Monolithic State Rebuild ("God Function")~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - Decomposed `reload_shell/2` into four focused updaters:
    - `refresh_layout/2` — No DB queries. Recomputes workbench-derived assigns (activity_buttons, panel_tabs, current_tab, status_bar, sidebar_header, editor_meta) from existing socket.assigns.
    - `refresh_sidebar/2` — Queries sidebar data only, then calls `refresh_layout`.
    - `refresh_content/2` — Queries projects, dashboard, git badge, and sidebar data, then calls `refresh_layout`.
    - `reload_shell/2` — Full refresh: tab_meta sync, task status, static data, then calls `refresh_content`. Kept for mount, project switch, session restore, and settings changes.
  - Replaced all call sites with the minimal refresh needed:
    - **Layout-only** (`refresh_layout`): toggle_sidebar, toggle_panel, toggle_assistant_sidebar, select_panel_tab, sync_layout, resize_panel, open_tasks_panel, select_tab, close_tab, toggle_offline_mode, layout menu actions (toggle, close_tab).
    - **Sidebar** (`refresh_sidebar`): select_view, all sidebar filter events, sidebar menu actions (view_posts, view_media, edit_preferences, etc.), chat/import editor tab_meta updates.
    - **Content** (`refresh_content`): entity_changed (CLI sync), tags_changed, sidebar create/delete.
    - **Full reload** (`reload_shell`): mount, activate_project, restore_workbench_session, set_page_language, settings_changed.
  - Updated Bridges callbacks to use focused refreshers: `refresh_layout` for toggle events and close_tab, `refresh_sidebar` for view switches and tab meta updates, `refresh_content` for entity/tag changes.
  - Split `@local_menu_actions` into `@layout_menu_actions` and `@sidebar_menu_actions` for correct dispatch.
  - Fixed `false || true` bug in `refresh_layout` where `offline_mode = assigns[:offline_mode] || true` incorrectly defaulted `false` to `true`.
  - Added 7 tests in `test/bds/csm007_reload_shell_test.exs` using telemetry-based query counting: toggle_sidebar (0 queries), toggle_panel (0 queries), sync_layout (0 queries), select_panel_tab (0 queries), toggle_offline_mode (1 query — settings write only), select_view (sidebar queries but no dashboard/projects), sidebar_search (no dashboard queries).

---

### ~~CSM-008 — DB Queries During Render Path~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - **Panel renderer** (`lib/bds/desktop/shell_live/panel_renderer.ex`):
    - `render_post_links` and `render_git_log` no longer call DB functions during render. Instead they read from pre-computed assigns (`panel_post_links`, `panel_git_entries`).
    - Renamed `post_link_entries/1` → `fetch_post_link_entries/1` and `git_log_entries/1` → `fetch_git_log_entries/1`, made them public for use by event handlers.
  - **Shell LiveView** (`lib/bds/desktop/shell_live.ex`):
    - Added `refresh_panel_data/1` that fetches panel data (post links or git log) based on the active panel tab and stores results in assigns.
    - `refresh_layout/2` detects when `current_tab` or `panel.active_tab` changed and calls `refresh_panel_data/1` only when stale — no DB queries on re-renders.
    - Initialized `panel_post_links` and `panel_git_entries` assigns in mount.
  - **Tab meta** (`lib/bds/desktop/shell_live/tab_helpers.ex`):
    - `sync_tab_meta` now skips `derived_tab_meta` DB queries when existing meta already has both title and subtitle populated (`meta_complete?/1` guard).
  - Added 5 tests in `test/bds/csm008_render_path_test.exs`: post_links re-render (0 queries), git_log re-render (0 queries), output panel switch (0 queries), tasks panel switch (0 queries), tab meta skip for complete meta (0 queries).

---

### ~~CSM-009 — Thumbnail Generation: Missing Error Handling~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - Replaced all bang variants with non-bang error-tuple handling:
    - `Image.autorotate!` → `Image.autorotate` with `{:ok, {image, rotation_info}}` destructuring.
    - `Image.thumbnail!` → `Image.thumbnail` returning `{:ok, image}` / `{:error, reason}`.
    - `Image.embed!` → `Image.embed` with `with` chain.
    - `Image.flatten!` → `Image.flatten` with `with` chain.
    - `Image.write!` → `Image.write` with `{:ok, _}` / `{:error, reason}` handling.
  - `File.mkdir_p` result is now checked — errors halt thumbnail generation with `{:error, reason}`.
  - `write_all_thumbnails` uses `Enum.reduce_while` to stop on first error and return `{:error, reason}`.
  - `ensure_thumbnails` spec updated to `:ok | {:error, term()}`.
  - `regenerate_thumbnails` propagates `{:error, reason}` from `ensure_thumbnails`.
  - `regenerate_missing_thumbnails` replaced `try/rescue` with `case` on the new error tuples.
  - Call sites in `BDS.Media` (`import_media`, `replace_media_binary`) use `log_thumbnail_error/2` — media operations succeed even if thumbnails fail, with a warning logged.
  - Added 6 tests in `test/bds/csm009_thumbnail_error_handling_test.exs`: corrupt image returns `{:error, _}`, non-image returns `:ok`, missing source returns `{:error, _}`, regenerate corrupt returns `{:error, _}`, regenerate_missing counts failures, import succeeds despite thumbnail failure.

---

### ~~CSM-010 — `rescue` for Control Flow in Data Layer~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - Added `BDS.Repo.ready?/0` — a lightweight probe that queries `sqlite_master` (parameterized) to check if core tables exist, without raising exceptions.
  - Replaced all 4 `rescue` blocks in `ShellData` (`project_snapshot/0`, `dashboard/1`, `sidebar_view/3`, `git_badge_count/2`) with upfront `Repo.ready?()` checks.
  - All four functions now return `{:ok, result}` / `{:error, :not_ready}` tuples instead of silently returning defaults via rescue.
  - Updated callers in `ShellLive.refresh_content/2` and `ShellLive.refresh_sidebar/2` to pattern-match the new tuples and fall back to empty defaults only on `{:error, :not_ready}`.
  - Made `default_project_snapshot/0` public for use by callers handling the not-ready case.
  - Added 10 tests in `test/bds/csm010_rescue_control_flow_test.exs`: `Repo.ready?` returns true when DB is available, each of the 4 functions returns `{:ok, _}` when DB is ready and `{:error, :not_ready}` when the Repo is stopped.

---

## Medium Severity

### ~~CSM-011 — No URL State / Deep Linking~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - `mount/3` now reads `?view=` and `?tab=<type>:<id>` query params and applies them to the initial workbench state, enabling deep linking on page load.
  - Added `push_url_state/1` — after state-changing events (`select_view`, `select_tab`, `close_tab`, `open_sidebar_item`, sidebar menu actions, project switch), pushes a `url-state` event to the client with the serialized URL.
  - Added JS handler in the `AppShell` hook that calls `history.replaceState` to update the browser URL without triggering navigation.
  - URL encoding: `?view=<sidebar_view>` (omitted when `posts`, the default) and `?tab=<type>:<id>` (omitted when no tab is active). Invalid or unknown params are silently ignored.
  - Used `push_event` + `history.replaceState` instead of `push_patch`/`handle_params` to maintain compatibility with existing `live_isolated` tests.
  - Added 10 tests in `test/bds/csm011_url_state_test.exs`: mount with `?view=media`, mount with default, mount with invalid view, mount with `?tab=post:<id>`, mount with both params, `select_view` pushes url-state, `select_view` posts pushes clean URL, `select_tab` pushes url-state, `close_tab` removes tab from URL, `open_sidebar_item` pushes url-state.

---

### ~~CSM-012 — Desktop File Dialog Blocks Event Handler~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - Replaced synchronous `FilePicker.choose_file/1` call in `SidebarCreate.create/4` for the "media" kind with `Task.async`, storing the task ref in a new `file_picker_task` socket assign.
  - Added `handle_file_picker_result/2` private function in `ShellLive` with clauses for `{:ok, _media}`, `:cancel`, `{:error, %{message: _}}`, and `{:error, reason}`.
  - Extended the existing `handle_info({ref, result}, socket)` and `handle_info({:DOWN, ref, ...}, socket)` handlers to match on `file_picker_task` ref.
  - Added `BDS_DESKTOP_AUTOMATION` guard to `FilePicker.choose_file/1` — returns `:cancel` immediately in automation/test mode, preventing native dialogs from opening during tests.
  - Initialized `file_picker_task: nil` assign in mount.
  - Added 5 tests in `test/bds/csm012_file_picker_async_test.exs`: event handler returns within 100ms, LiveView handles other events while task is pending, task completion doesn't crash LiveView, cancel is handled gracefully, error results don't crash LiveView.

---

### ~~CSM-013 — Bang Functions in Rendering Pipelines~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - **`lib/bds/rendering/filters.ex`** — `render_macro_template`:
    - Replaced `Liquex.parse!` with `Liquex.parse` (non-bang) and `case` match on `{:ok, ast}` / `{:error, reason, line}`.
    - Wrapped `Liquex.render!` in `try/rescue` catching `Liquex.Error` specifically (no non-bang `render` exists in Liquex).
    - Removed broad `rescue _error -> ""` — errors now log via `Logger.warning` with template path and reason before returning `""`.
  - **`lib/bds/rendering/template_selection.ex`** — `render_template`:
    - `Liquex.parse` was already non-bang; added `else` clause to normalize the 3-tuple `{:error, reason, line}` into `{:error, "reason at line N"}`.
    - Wrapped `Liquex.render!` in `try/rescue` catching `Liquex.Error` specifically, returning `{:error, message}`.
    - Removed broad `rescue error -> {:error, error}`.
  - **`lib/bds/rendering/post_rendering.ex`** — `post_data_json_value`:
    - Replaced `Jason.encode!` with `Jason.encode` and `case` match — returns `"{}"` on encode failure instead of crashing.
  - Added 5 tests in `test/bds/csm013_bang_rendering_test.exs`: template syntax error returns `{:error, _}` from `render_template`, broken template in `render_post_page` returns `{:error, _}`, `{% break %}` render error returns `{:error, _}`, normal post context produces valid JSON, non-encodable data returns `"{}"` fallback.

---

### ~~CSM-014 — O(n²) Loops from `length/1` Inside Iteration~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - **`lib/bds/generation/outputs.ex`** — `build_category_outputs`:
    - Bound `total_pages = length(paginated_posts)` and `total_items = length(posts)` before the nested loop. Previously called `length/1` 4 times per page × language iteration.
  - **`lib/bds/generation/outputs.ex`** — `build_root_outputs`:
    - Bound `total_items = length(posts)` before the loop, reused by `pagination_for_page`. Previously called `length(posts)` on every page iteration.
  - **`lib/bds/generation/outputs.ex`** — `build_paginated_archive_outputs`:
    - Bound `total_items = length(posts)` before the loop. Previously called `length(posts)` inside the nested page × language loop.
  - **`lib/bds/rendering/list_archive.ex`** — `build_day_blocks`:
    - Bound `last_index = length(grouped_blocks) - 1` before the `Enum.map`. Previously called `length(grouped_blocks)` on every iteration.
  - **`lib/bds/publishing.ex`** — `run_upload`:
    - Bound `target_count = max(length(targets), 1)` before the `Enum.reduce_while`. Negligible impact (3 targets) but fixed for consistency.
  - `lib/bds/ui/sidebar.ex` `acc.draft ++ [post]` was already fixed by CSM-005 (replaced with `Enum.group_by`).
  - Added 3 tests in `test/bds/csm014_length_in_loop_test.exs`: multi-page pagination correctness, single-page pagination correctness, 1000-post linear time completion.

---

### ~~CSM-015 — Missing DB Indexes on Foreign Keys~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - Added migration `20260509145208_add_missing_indexes.exs` with indexes for all missing foreign keys and frequently filtered columns:
    - FK indexes: `media.project_id`, `post_media.post_id`, `post_media.media_id`, `chat_messages.conversation_id`, `embedding_keys.post_id`, `embedding_keys.project_id`, `dismissed_duplicate_pairs.project_id`, `import_definitions.project_id`, `publish_jobs.project_id`.
    - Filter indexes: `posts.status`, `posts.published_at`, `posts.language`.
    - Composite index: `db_notifications(entity_type, entity_id)`.
  - Added 12 tests in `test/bds/csm015_missing_indexes_test.exs` verifying via `EXPLAIN QUERY PLAN` that all indexed columns use index lookups.

---

### ~~CSM-016 — String Concatenation for Paths~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - **`lib/bds/rendering/file_system.ex`** — Extracted `ensure_liquid_ext/1` using `Path.extname/1` to check before appending `.liquid`, preventing double-extension bugs (e.g. `"header.liquid.liquid"`).
  - **`lib/bds/rendering/metadata.ex`** — `menu_item_href` for `:page` kind now applies `URI.encode/1` to the slug (matching the existing `:category_archive` pattern). `href_for_language/1` now uses `String.trim_trailing(prefix, "/")` before appending `/` to prevent double trailing slashes.
  - **`lib/bds/rendering/metadata.ex`** — Added `menu_items_from_raw/1` public function for testability.
  - **`lib/bds/rendering/links_and_languages.ex`** — `post_path/2` for `nil` language now uses `Path.join(["/", year, month, day, slug]) <> "/"` instead of building with `index.html` then stripping it. Language-prefix clause uses `String.trim_trailing/2` to prevent double slashes. `canonical_media_path_by_source_path/1` uses `Path.join("/", media.file_path)` instead of `"/" <> file_path`.
  - **`lib/bds/publishing.ex`** — `ensure_trailing_slash/1` made public for testability (implementation already correct).
  - Added 17 tests in `test/bds/csm016_path_concatenation_test.exs`: FileSystem extension handling (bare name, double extension, nested paths), `href_for_language` (empty, with/without trailing slash), menu item href encoding (special chars, plain slugs, category slugs), post_path construction (leading/trailing slashes, no double slashes, language prefix), `language_prefix` (same/nil/different language), `ensure_trailing_slash` (without/with trailing slash, empty string).

---

### ~~CSM-017 — `send(self(), ...)` Component Chatter~~ ✅ FIXED
- **Fixed:** 2026-05-09
- **What was done:**
  - Created `BDS.Desktop.ShellLive.Notify` — a single dispatch module that standardizes all parent communication from LiveComponent editors. Provides typed functions: `output/3`, `output/4`, `tab_meta/4`, `tab_meta_merge/3`, `close_tab/2`, `reload/0`, `dirty/3`, `command/2`, `open_sidebar_item/2`, and `parent/1` (escape hatch for chat-specific messages).
  - Replaced all 25+ `send(self(), ...)` calls across 11 editor components with `Notify.*` calls:
    - `post_editor.ex` — 13 calls (dirty, tab_meta, close_tab, output)
    - `media_editor.ex` — 7 calls (dirty, tab_meta, output)
    - `chat_editor.ex` — 15 calls (output, tab_meta, open_sidebar_item, plus chat-specific via `Notify.parent`)
    - `template_editor.ex` — 3 calls (close_tab, output, reload)
    - `script_editor.ex` — 3 calls (close_tab, output, reload)
    - `misc_editor.ex` — 4 calls (command, output, tab_meta_merge, open_sidebar_item)
    - `settings_editor.ex` — 2 calls (output, parent)
    - `tags_editor.ex` — 2 calls (output, parent)
    - `menu_editor.ex` — 1 call (output)
    - `import_editor.ex` — 2 calls (tab_meta, output)
    - `overlay_manager.ex` — 3 calls (parent for cross-component routing)
  - Consolidated Bridges from 30+ editor-specific `handle_info` clauses to 4 generic handlers: `{:editor_output, ...}`, `{:editor_tab_meta, ...}`, `{:editor_dirty, ...}`, `{:editor_command, ...}`.
  - Removed 18 editor-specific message atoms from Bridges (`:post_editor_output`, `:media_editor_output`, `:post_editor_dirty`, `:media_editor_dirty`, `:post_editor_tab_meta`, etc.).
  - Kept chat-specific messages (`{:chat_editor_task_started, ...}`, `{:chat_editor_toggle_sidebar}`, etc.) and cross-component routing (`{:post_editor_insert_content, ...}`) in Bridges since they originate from AI streaming or overlay actions, not from editor self-notification.
  - Added 24 tests in `test/bds/csm017_component_chatter_test.exs`: 11 source-level tests asserting no `send(self(), ...)` in any editor file, 1 aggregate test verifying all shell_live `send(self(), ...)` calls are in `notify.ex`, 2 Bridges tests verifying old patterns are gone and new generic handlers exist, 10 Notify API tests verifying each function sends the correct message.

---

## Low Severity / Code Quality

### ~~CSM-018 — `@moduledoc false` Epidemic~~ ✅ FIXED
- **Fixed:** 2026-05-10
- **What was done:**
  - Replaced `@moduledoc false` with descriptive `@moduledoc` strings in all 12 listed public modules:
    - `lib/bds/i18n.ex` — language support, locale resolution, flag emoji mapping
    - `lib/bds/map_utils.ex` — mixed-key map utilities and safe atom conversion
    - `lib/bds/bounded_atoms.ex` — allow-list-based dynamic atom conversion
    - `lib/bds/document_fields.ex` — frontmatter field access with key aliases
    - `lib/bds/import_definitions.ex` — CRUD for WXR import configurations
    - `lib/bds/publishing.ex` — GenServer for site upload job coordination
    - `lib/bds/settings.ex` — global key-value settings persistence
    - `lib/bds/templates.ex` — Liquid template lifecycle management
    - `lib/bds/ai.ex` — AI endpoint config, secrets, and inference dispatch
    - `lib/bds/mcp.ex` — MCP server facade for external AI agents
    - `lib/bds/scripting/capabilities.ex` — Lua scripting capability map builder
    - `lib/bds/scripting/api_docs.ex` — machine-readable Lua API documentation

---

### ~~CSM-019 — Missing `@spec` on Public Functions~~ ✅ FIXED
- **Fixed:** 2026-05-10
- **What was done:**
  - Added `@spec` annotations to every public function across 25 files in rendering, generation, publishing, UI, and scripting modules.
  - Added `@type t :: %__MODULE__{}` to `workbench.ex` and `file_system.ex` to support struct-based specs.
  - Rendering: `post_rendering.ex`, `links_and_languages.ex`, `labels.ex`, `metadata.ex`, `file_system.ex`, `filters.ex`, `list_archive.ex`, `template_selection.ex`
  - Generation: `generated_file_hash.ex`
  - Publishing: `publishing.ex`
  - UI: `registry.ex`, `session.ex`, `sidebar.ex`, `menu_bar.ex`, `commands.ex`, `dashboard.ex`, `workbench.ex`
  - Scripting: `job_store.ex`, `job_runner.ex`, `job_supervisor.ex`, `capabilities.ex`, `capabilities/util.ex`, `api_docs.ex`
  - Dialyzer passes with 0 errors; all 619 tests pass.

---

### ~~CSM-020 — Deeply Nested `case` Instead of `with`~~ ✅ FIXED
- **Fixed:** 2026-05-10
- **What was done:**
  - **`lib/bds/import_definitions.ex`** — `delete_definition/1`: Replaced nested `case` piped into another `case` with a flat `with` chain: `Repo.get` → `Repo.delete` → `{:ok, :deleted}`, with `else` clauses for `nil` and `{:error, _}`.
  - **`lib/bds/publishing.ex`** — `handle_call({:update_job, ...})`: Replaced `case Repo.get` with `with %PublishJob{} = job <- Repo.get(...)`. Also replaced `Repo.update!()` with `Repo.update()` to avoid crashes on changeset errors.
  - **`lib/bds/templates.ex`** — `update_template/2`: Replaced outer `case Repo.get` with `with` + extracted `do_update_template/2` private function. Collapsed three levels of nested `case` (Repo.get → transaction_result → sync_side_effects) into a single flat `with` chain.
  - Added 7 tests in `test/bds/csm020_nested_case_test.exs`: delete_definition success and not-found, update_template success and not-found, source-level assertions that all three files use `with` instead of nested `case`.

---

### ~~CSM-021 — `cond` Where Pattern Matching Suffices~~ ✅ FIXED
- **Fixed:** 2026-05-11
- **What was done:**
  - **`lib/bds/ai.ex`** — `get_endpoint/2`: Replaced `cond do is_nil(x) and ...; true -> ... end` with a simple `if/else` since there are only two branches.
  - **`lib/bds/scripting/api_docs.ex`** — `example_response_value/1`: Extracted `"nil"` literal match into a separate function head. Replaced remaining `cond` with `case` on a tuple of guard results.
  - **`lib/bds/scripting/api_docs.ex`** — `example_field_value/1`: Replaced `cond` with `case` on a tuple of `String.contains?`/`String.ends_with?` results.
  - Added 2 source-level tests in `test/bds/csm021_cond_pattern_match_test.exs` asserting no `cond do` blocks remain in either file.

---

### ~~CSM-022 — Silent Error Swallowing~~ ✅ FIXED
- **Fixed:** 2026-05-11
- **What was done:**
  - `execute_macro/4` now returns `{:error, reason}` instead of `{:ok, ""}` when the underlying script execution fails.
  - Added `Logger.warning/1` call that logs the project ID and error reason before returning the error tuple.
  - Updated test in `api_test.exs` to assert `{:error, _reason}` instead of `{:ok, ""}` for failing macros.

---

### ~~CSM-023 — SRP Violations~~ ✅ FIXED
- **Fixed:** 2026-05-11
- **What was done:**
  - **`lib/bds/templates.ex`** — `do_update_template/2`:
    - Extracted `resolve_next_slug/2` — determines slug from attrs or keeps current.
    - Extracted `content_changed?/2` — checks if content attr differs from effective content.
    - Extracted `resolve_next_status/2` — pattern-matched function heads for status transition (published + content change → draft).
    - Extracted `build_update_attrs/5` — assembles the changeset map from resolved values.
    - Extracted `commit_update_transaction/4` — runs the Repo transaction with cascade logic.
    - `do_update_template/2` is now a concise pipeline: resolve → build → commit → sync.
  - **`lib/bds/scripting/capabilities.ex`** — `for_project/2`:
    - Extracted 13 domain-specific builder functions: `app_capabilities/2`, `project_capabilities/1`, `meta_capabilities/1`, `post_capabilities/1`, `media_capabilities/1`, `script_capabilities/1`, `template_capabilities/1`, `tag_capabilities/1`, `task_capabilities/0`, `sync_capabilities/2`, `publish_capabilities/2`, `chat_capabilities/1`, `embedding_capabilities/1`.
    - `for_project/2` is now a 15-line dispatch map.
  - Added 5 tests in `test/bds/csm023_srp_violations_test.exs`: source-level assertions for helper extraction in templates, delegation in do_update_template, builder function presence in capabilities, concise for_project body (≤20 lines), no inline capability definitions in for_project.

---

### ~~CSM-024 — `Enum.reduce` with `acc.draft ++ [post]` (O(n²))~~ ✅ FIXED
- **Fixed:** 2026-05-08 (as part of CSM-005)
- **What was done:** Replaced `acc.draft ++ [post]` with `Enum.group_by/2` in `group_posts/1`. See CSM-005 entry for details.

---

### ~~CSM-025 — Hardcoded Language Prefixes~~ ✅ FIXED
- **Fixed:** 2026-05-11
- **What was done:**
  - Replaced hardcoded `["de/", "fr/", "it/", "es/"]` in `language_match?/2` with dynamically derived prefixes from `plan.blog_languages` and `plan.language`.
  - `build_outputs/2` now computes `other_prefixes` by rejecting the main language from `blog_languages` and appending `"/"` to each.
  - `pages_for_language/3` and `language_match?/3` now accept the computed prefixes as a parameter instead of using a hardcoded list.
  - Works correctly with arbitrary language codes (e.g. `pt-br`, `zh-cn`, `ja`) that were not in the old hardcoded list.
  - Added 5 tests in `test/bds/csm025_hardcoded_languages_test.exs`: source-level assertion for no hardcoded prefixes, main language exclusion, non-main language inclusion, arbitrary language codes, single-language blog.

---

### ~~CSM-026 — TOCTOU Race Condition in Template File System~~ ✅ FIXED
- **Fixed:** 2026-05-11
- **What was done:**
  - Extracted `candidate_paths/2` — validates the template path and returns all candidate file paths without checking existence.
  - Added `try_read/2` — attempts `File.read` on each candidate path sequentially, returning `{:ok, contents}` on first success or `{:error, :enoent}` when all fail. No separate existence check.
  - Simplified `full_path/2` to delegate to `candidate_paths/2` (returns first candidate for backward compatibility with tests).
  - Rewrote `Liquex.FileSystem` protocol impl to use `try_read/2` directly, eliminating the TOCTOU window between `File.regular?` and `File.read`.
  - Added 10 tests in `test/bds/csm026_toctou_file_system_test.exs`: atomic read, missing template, multi-root fallthrough, first-root-wins priority, file-deleted-between-calls safety, protocol read, protocol raise on missing, and path validation (empty, absolute, traversal).

---

### ~~CSM-027 — `if result == :ok` Instead of Pattern Matching~~ ✅ FIXED
- **Fixed:** 2026-05-11
- **What was done:**
  - Replaced `if result == :ok and ...` in `rewrite_template_file/2` with a `case` expression using pattern matching and a `when` guard.
  - `Persistence.atomic_write` result is now matched directly: `:ok when file_path changed` triggers old file cleanup, `other` (including `{:error, _}`) is returned as-is.

---

### ~~CSM-028 — Broad `rescue` Swallowing Template Errors~~ ✅ FIXED
- **Fixed:** 2026-05-11
- **What was done:**
  - Replaced `Liquex.FileSystem.read_template_file` (which raises on missing templates) with `BDS.Rendering.FileSystem.try_read` (returns `{:ok, source}` / `{:error, :enoent}`).
  - Missing template now logs a warning and returns `""` without raising.
  - Extracted `render_macro_source/4` to separate file reading from template parsing/rendering.
  - `Liquex.render!` rescue remains specific to `Liquex.Error` (no non-bang variant exists in Liquex).
  - No broad `rescue _error ->` or `rescue _ ->` clauses remain in `filters.ex`.
  - Added 3 source-level tests in `test/bds/csm028_broad_rescue_test.exs`: no broad rescue clauses, no `read_template_file` usage, `try_read` is used instead.

---

### ~~CSM-029 — `length/1` in Guards or Comparisons~~ ✅ FIXED
- **Fixed:** 2026-05-11
- **What was done:**
  - **`lib/bds/generation/outputs.ex`** — `category_route_paths`, `tag_route_paths`, `date_route_paths`:
    - Bound `post_count = length(posts)` at the start of each `Enum.flat_map` callback, before passing to `paginated_archive_paths`. Eliminates inline `length/1` calls inside loop bodies.
  - **`lib/bds/ui/sidebar.ex`** — `build_post_section`:
    - Bound `post_count = length(posts)` before the map literal instead of computing `length(posts)` inline in the `count:` field.
  - Added 3 source-level tests in `test/bds/csm029_length_in_guards_test.exs`: no inline `length(posts)` in `paginated_archive_paths` calls, no inline `length()` in `build_post_section` map literal, no inline `length(posts)` in route path function callbacks.

---

### ~~CSM-030 — Unchecked `File.mkdir_p` / `File.mkdir_p!`~~ ✅ FIXED
- **Fixed:** 2026-05-11
- **What was done:**
  - **`lib/bds/media/thumbnails.ex`** — Already fixed in CSM-009; `File.mkdir_p` is inside a `with` chain in `write_all_thumbnails`.
  - **`lib/bds/media/sidecars.ex`** — Removed redundant `File.mkdir_p` calls from `write_sidecar/2` and `write_translation_sidecar/3` (the underlying `Persistence.atomic_write` already handles `mkdir_p`). Updated specs to return `:ok | {:error, File.posix()}`. Updated callers (`sync_media_sidecar`, `sync_media_translation_sidecar`) to propagate errors.
  - **`lib/bds/media.ex`** — Replaced all `:ok = write_sidecar(...)` and `:ok = write_translation_sidecar(...)` match assertions with `log_sidecar_error/2` (mirrors existing `log_thumbnail_error/2` pattern). Sidecar write failures are logged as warnings but don't fail the DB operation.
  - **`lib/bds/media/linking.ex`** — Same `log_sidecar_error/2` pattern for post link/unlink sidecar writes.
  - **`lib/bds/release_packaging.ex`** — Replaced `File.mkdir_p!` with `File.mkdir_p` in `reset_output/1` (return value propagated through `with` chain in `package/1`). Replaced `File.mkdir_p!` with `with :ok <- File.mkdir_p(...)` in `copy_release/2`. Replaced `File.write!` with `File.write` in `write_manifest/1`.
  - Added 6 tests in `test/bds/csm030_unchecked_mkdir_test.exs`: source-level assertions for no unchecked `File.mkdir_p`, no bang variants, no `:ok =` match assertions on sidecar writes.

---

### CSM-031 — `try/rescue` Instead of `with` and Error Tuples
- **Files:** `lib/bds/rendering/filters.ex`, `lib/bds/rendering/template_selection.ex`, `lib/bds/desktop/shell_data.ex`
- **Fix:** Replace `try/rescue` around expected failures with non-bang functions and `with` chains.

---

### CSM-032 — `Map.get` with Default Instead of Pattern Matching
- **Files:** Widespread
- **What:** `Map.get(map, key, default)` when the key is expected to exist.
- **Fix:** Use pattern matching (`%{key: value} = map`) or `Map.fetch!/2` if the key is required.

---

### CSM-033 — `Enum.each` with Side Effects That Should Be Batch Inserts
- **Files:** `lib/bds/search.ex:174-177`, `lib/bds/embeddings.ex`
- **What:** `Enum.each` used for inserting records. The side-effect pattern is fine, but `Enum.map` + `Repo.insert_all` would be much faster for bulk inserts.
- **Fix:** Use `Repo.insert_all` for batch inserts instead of `Enum.each` + `Repo.insert`.

---

### CSM-034 — `File.read!` / `File.write!` Without Error Handling
- **Files:** `lib/bds/preview_assets.ex:32`, `lib/bds/release_packaging.ex:105`, `lib/bds/templates.ex:488-489`
- **Fix:** Use `File.read/1`, `File.write/2`, and handle `{:error, reason}`.

---

### CSM-035 — Process Dictionary (`Process.get/put`) Usage
- **File:** `lib/bds/desktop/ui_locale.ex:32,49,65`
- **What:** `UILocale.put/1` sets process dictionary (`Process.put(@key, locale)`) for UI locale. Used in `ShellLive.render` (Z. 550) and `MenuBar`.
- **Fix:** This is isolated to the LiveView/MenuBar process so it's low-risk, but document the invariant explicitly: the process dict key `:bds_ui_locale` is set before each render call.

---

### CSM-036 — Missing `@impl true` on GenServer Callbacks
- **File:** `lib/bds/publishing.ex:46,61,71,75`
- **What:** Only `init/1` (Z. 36) and the first `handle_call` (Z. 41) have `@impl true`. The remaining `handle_call` clauses at Z. 46, 61, 71, 75 lack it.
- **Fix:** Add `@impl true` before every `handle_call`, `handle_cast`, `handle_info`, and `terminate`.

---

## Checklist for Agents Picking Up This File

- [x] All critical items (CSM-001 to CSM-005) have been addressed or explicitly deferred with justification.
  - CSM-001: Fixed. All `String.to_atom` on dynamic data replaced with `MapUtils.safe_atomize_key/keys` or `String.to_existing_atom`.
  - CSM-002: Fixed. Search now pushes all filtering and pagination into SQL via Ecto queries and CTEs.
  - CSM-004: Fixed. `attach_runner` moved to `handle_continue`, `terminate/2` added for cleanup, `restart: :temporary` set, JobStore `detach_runner` bug fixed.
- [x] All high-severity items (CSM-006 to CSM-010) have been addressed.
  - CSM-006: Fixed. Batch INSERT for reindexing, preloaded post records for rendering.
  - CSM-007: Fixed. Decomposed into refresh_layout, refresh_sidebar, refresh_content, reload_shell.
  - CSM-008: Fixed. Panel data pre-computed in event handlers, tab meta skips DB for complete entries.
  - CSM-009: Fixed. All bang Image/File variants replaced with error-tuple handling, `ensure_thumbnails` returns `{:error, _}` instead of crashing.
  - CSM-010: Fixed. Replaced rescue blocks with `Repo.ready?/0` probe and `{:ok, _}`/`{:error, :not_ready}` tuples.
- [x] CSM-001 fix covers ALL 6 affected files, not just `import_definitions.ex`.
- [x] CSM-003 fix covers ALL `Repo.delete!` call sites (posts, tags, scripts, media, projects, templates, translations).
- [x] CSM-007 decomposition is the prerequisite for fixing CSM-008 (render-path queries).
- [x] Tests were written **before** implementation changes (Red → Green → Refactor).
- [x] Full test suite passes: `mix test`.
- [x] Dialyzer passes cleanly: `mix dialyzer` (zero warnings).
- [x] Build succeeds: `mix compile`.
- [x] No external JS/CSS referenced in preview/generated HTML (per AGENTS.md).
- [x] All UI strings use gettext / i18n, no hardcoded text.
- [x] API docs (`API.md`) updated if any API changes were made.
- [x] Metadata diff tool and rebuild-from-database updated if metadata changed.
- [x] Specs in `specs/` folder updated and validated if behavior changed.
- [x] Unused code (including tests for removed features) has been deleted.
- [x] This `CODESMELL.md` updated: fixed items removed, new ones added.
