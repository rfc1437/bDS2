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

### CSM-001 — Atom Table Exhaustion Vulnerability
- **What:** `String.to_atom/1` on user-controlled data creates atoms that are never GC'd. A malicious payload can exhaust the ~1M atom limit and crash the VM.
- **Affected files (all must be fixed):**
  - `lib/bds/import_definitions.ex:101` — `atomize_keys/1` converts all JSON keys from import analysis data
  - `lib/bds/import_execution.ex:541` — `normalize_report/1` converts import execution report keys
  - `lib/bds/ai/catalog.ex:215` — `Enum.into(map, %{}, fn {k,v} -> {String.to_atom(k), v})` on catalog data
  - `lib/bds/ai/catalog.ex:316` — `parse_modality/1` on provider data
  - `lib/bds/ai/chat_tools.ex:912` — `maybe_put(acc, String.to_atom(key), arguments[key])` on tool arguments
  - `lib/bds/desktop/automation.ex:380` — `normalized_key` on automation event data
- **NOT affected:** `lib/bds/bounded_atoms.ex` uses safe string-only matching, no `String.to_atom`. `lib/bds/ui/menu_bar.ex:124,134` and `lib/bds/ui/workbench.ex:270` convert internal IDs (controlled vocabulary), which is lower risk but should still use `String.to_existing_atom/1`.
- **Fix:** Replace all `String.to_atom(key)` with `String.to_existing_atom(key)` or keep keys as strings. For the import/analysis results, keep keys as strings since the consumer code can use `Map.get(map, "key")` or `Access.key/2`. For internal IDs (menu_bar, workbench), ensure the atoms exist in the module attribute allow-lists before conversion.
- **Test:** For each file: create a payload with 100k unique string keys; verify atom count (`:erlang.system_info(:atom_count)`) does not increase.

---

### CSM-002 — Search Loads Entire Tables into Memory
- **File:** `lib/bds/search.ex:111-149`
- **What:** `search_posts/3` and `search_media/3` load **all** candidate IDs via `candidate_post_ids`, then **all** matching records via `load_posts_in_order`, then filter in Elixir (`filter_posts`), then paginate in Elixir (`paginate`).
- **Why it's bad:** For a project with thousands of posts, every search fetches the entire table into the BEAM process. Filtering (status, tags, categories, language, year, month, date range, missing translations) and pagination all happen in Elixir instead of SQL.
- **Fix:**
  - Push `where` clauses for status, language, year/month, and date range into the Ecto query.
  - Use `Repo.aggregate(:count)` for total instead of `length(posts)`.
  - Push `limit`/`offset` into SQL for pagination.
  - For tag/category overlap filtering, use a `JOIN` or subquery on the FTS index.
  - `filter_posts` (Z. 348-371) should become SQL where-clauses, not an `Enum.filter`.
- **Test:** Create a project with 5,000 posts; run a search; assert memory stays below 50MB and query completes in <200ms.

---

### CSM-003 — Non-Atomic Side Effects in Post CRUD
- **File:** `lib/bds/posts.ex`
- **What:** `create_post/1` (Z. 65-108), `update_post/2` (Z. 112-151), `publish_post/1` (Z. 155-195), `delete_post/1` (Z. 298-320) mix DB writes with filesystem/search/embeddings side effects.
- **Why it's bad:**
  - If a side effect fails after the DB commit, the system is inconsistent (DB says one thing, filesystem another).
  - `delete_post/1` (Z. 312-318) deletes files (`delete_post_file`), removes embeddings, deletes post links — all **before** `Repo.delete!(post)`. If `Repo.delete!` raises, the files are gone but the row remains.
  - `Repo.delete!` (bang) crashes instead of returning `{:error, _}`.
  - Same pattern with `Repo.delete!` in `tags.ex:153,232`, `scripts.ex:133`, `media.ex:184,250`, `projects.ex:190`, `templates.ex:216,535`, `posts/translations.ex:101`, `posts/translation_validation.ex:399`.
- **Fix:**
  - Use `Repo.transaction` or `Ecto.Multi` to group DB writes atomically.
  - Perform filesystem side effects **after** the DB commit succeeds (use `Repo.transaction` callback or `Ecto.Multi` with `run/5`).
  - Replace all `Repo.delete!` with `Repo.delete` and handle `{:error, _}` tuples.
  - In `delete_post/1`: reorder to `Repo.delete` first, then clean up files/embeddings/search.
- **Test:** Mock a file-delete failure in `delete_post/1`; assert the post row still exists.

---

### CSM-004 — Blocking `init/1` + Missing `terminate/2` in Job Runner
- **File:** `lib/bds/scripting/job_runner.ex:28-35`
- **What:**
  1. Synchronous `GenServer.call` to `JobStore.attach_runner/2` inside `init/1` (Z. 30) blocks the supervisor if `JobStore` is slow.
  2. `Process.flag(:trap_exit, true)` (Z. 29) is set but there is **no** `terminate/2` callback and **no** `{:EXIT, ...}` handler in `handle_info`.
- **Why it's bad:**
  - Supervisor child startup hangs if `JobStore` is slow or unavailable.
  - If the runner process is killed (not via `:cancel`), the PID leaks in `JobStore.runners`. The `detach_runner/2` call only happens in `handle_call(:cancel)` (Z. 71) and `handle_info({ref, result})` (Z. 95) and `handle_info({:DOWN, ...})` (Z. 117). A linked process crash with `trap_exit` would send `{:EXIT, pid, reason}` which has **no handler**, so the runner stops without detaching.
- **Fix:**
  - Move `attach_runner` to `handle_continue/2`.
  - Either remove `trap_exit` (the task uses `async_nolink`, so links aren't the issue) OR add `terminate/2` that calls `JobStore.detach_runner/2` and add an `{:EXIT, ...}` clause in `handle_info`.
- **Test:** Start a runner, kill it (not via cancel); assert `JobStore` does not contain the dead PID.

---

### CSM-005 — Client-Side Filtering of Entire Tables
- **Files:** `lib/bds/ui/sidebar.ex`, `lib/bds/tags.ex`, `lib/bds/ui/dashboard.ex`
- **What:**
  - `UI.Sidebar.list_posts/1` (Z. 464-482) loads every post for a project, then `apply_post_filters/1` (Z. 608-615) filters in Elixir. Translation counts are a separate query but still unbounded.
  - `Tags.posts_with_tag/2` (Z. 310-312) and `Tags.posts_with_any_tag/2` (Z. 314-316) load **all posts** to filter by tag name. `Tags.post_tag_names/1` (Z. 320-322) loads all posts to extract tag names.
  - `UI.Dashboard.snapshot/1` (Z. 14-35) loads ALL posts and ALL media for counts and stats. Post stats (Z. 77-87) and media stats (Z. 89-96) are computed in Elixir via `Enum.reduce`.
  - `Posts.dashboard_stats/1` (posts.ex:374-394) loads all post statuses and counts in Elixir.
- **Fix:**
  - Sidebar: Use `Repo.aggregate` for counts, `where` clauses for filters, `limit`/`offset` for pagination. Preload tag colors separately.
  - Tags: Use `where: fragment("? IN (?)", ^tag_name, post.tags)` or JSON functions. For `post_tag_names`, use `Repo.aggregate` + `distinct`.
  - Dashboard: Use `Repo.aggregate(:count)` with `group_by` for status counts, media counts, tag clouds, and category counts. No need to load full records.
  - `dashboard_stats`: Replace with `from post in Post, where: post.project_id == ^project_id, group_by: post.status, select: {post.status, count(post.id)}`.
- **Test:** Create 10,000 posts; open the sidebar; assert the LiveView process memory stays bounded.

---

## High Severity

### CSM-006 — N+1 Queries in Reindexing & Rendering
- **Files:** `lib/bds/search.ex:166-177`, `lib/bds/rendering/list_archive.ex:181`, `lib/bds/rendering/post_rendering.ex:21`
- **What:**
  - `Search.reindex_posts/1` (Z. 172-177) calls `insert_post_index/1` per post inside `Enum.each`; `insert_post_index` calls `post_index_fields/1` (Z. 268) which calls `post_translations/1` (Z. 494) — one query per post for translations. Same for media reindexing.
  - `ListArchive` (Z. 181) and `PostRendering` (Z. 21) call `load_post_record/1` per-post inside `Enum.map`, which does `Repo.get(Post, post_id)` per iteration.
- **Fix:** Preload all translations in a single query before the loop, or batch-insert with `Repo.insert_all`. For rendering, preload all needed records in one query.
- **Test:** Reindex 100 posts; assert the total query count is <5 (use `Ecto.Adapters.SQL.query!/2` hook or logger capture).

---

### CSM-007 — Monolithic State Rebuild ("God Function")
- **File:** `lib/bds/desktop/shell_live.ex:554-616`
- **What:** `reload_shell/2` rebuilds sidebar, dashboard, git badge, tasks, status bar, tab meta, and panel data on almost every event. This function is called from most `handle_event` and `handle_info` callbacks, even for trivial state changes like sidebar toggle.
- **Why it's bad:** Even a simple sidebar toggle triggers 5+ unrelated DB queries (project_snapshot, dashboard, git_badge_count, sidebar_view, task_status). The sidebar and dashboard data are rebuilt even when only the panel content changed. Output entries and editor meta are recalculated unnecessarily.
- **Fix:** Decompose into focused updaters, each only querying what it needs:
  - `refresh_sidebar/2` — only queries sidebar data
  - `refresh_dashboard/2` — only queries dashboard data
  - `refresh_git_badge/2` — only queries git status
  - `refresh_task_status/2` — only queries task state
  - `refresh_tab_meta/2` — only syncs tab metadata
  Each `handle_event` / `handle_info` should call only the relevant updaters.
- **Test:** Toggle sidebar; assert no dashboard or git queries are executed. Save a post; assert sidebar refreshes but dashboard does not.

---

### CSM-008 — DB Queries During Render Path
- **Files:** `lib/bds/desktop/shell_live/panel_renderer.ex`, `lib/bds/desktop/shell_live/tab_helpers.ex`
- **What:**
  - `panel_renderer.ex:199-209` — `post_link_entries/1` calls `PostLinks.list_incoming_links/1` and `Posts.get_post/1` per link during render.
  - `panel_renderer.ex:229-240` — `git_log_entries/1` calls `Git.file_history/2` and `Posts.get_post/1` during render.
  - `tab_helpers.ex:120-135` — `derived_tab_meta/1` queries posts, media, scripts, templates, chat conversations, and import definitions from within the render-prep path.
- **Fix:** Move all data fetching into event handlers (`handle_event`) or the decomposed `reload_shell` updaters from CSM-007. Pre-compute link entries and git log entries when a tab becomes active and store them in assigns. Render should be a pure function of assigns.
- **Test:** Render a panel 10 times; assert no DB queries fire on re-renders.

---

### CSM-009 — Thumbnail Generation: Missing Error Handling
- **File:** `lib/bds/media/thumbnails.ex:107-165`
- **What:**
  - `Image.thumbnail!` (Z. 149,154) and `Image.write!` (Z. 159,164) are bang variants that crash on failure.
  - `File.mkdir_p/1` (Z. 133) result is discarded — if directory creation fails, the write will crash with a confusing error.
  - `Image.embed!` (Z. 150) and `Image.flatten!` (Z. 158) are also bang variants.
- **Note on scheduler blocking:** The `Image` library uses libvips NIFs which run image processing in a C thread pool, not on the BEAM scheduler. The original concern about scheduler blocking is **not substantiated** for this library. The real issues are the bang variants and unchecked `File.mkdir_p`.
- **Fix:**
  - Replace `File.mkdir_p/1` with `case File.mkdir_p(dir) do :ok -> ...; {:error, reason} -> {:error, reason}`.
  - Replace bang `Image.thumbnail!` with `Image.thumbnail` and handle `{:error, _}`.
  - Replace bang `Image.write!` with `Image.write` and handle `{:error, _}`.
  - Wrap the whole `write_all_thumbnails` in a try/return-error-tuple pattern.
- **Test:** Feed a corrupt image; assert `ensure_thumbnails` returns `{:error, _}` instead of crashing.

---

### CSM-010 — `rescue` for Control Flow in Data Layer
- **File:** `lib/bds/desktop/shell_data.ex:64-74, 81-103, 152-182`
- **What:** `rescue Exqlite.Error`, `rescue DBConnection.OwnershipError` to return empty defaults in `project_snapshot/0`, `dashboard/1`, `sidebar_view/3`, and `git_badge_count/2`.
- **Why it's bad:** Exceptions are for exceptional conditions. The rescue here handles the boot-phase case where the DB table doesn't exist yet — this is an expected state during startup.
- **Nuance:** The code does check `Exception.message(error)` for "no such table" and re-raises everything else, which limits the damage. But it's still control-flow-via-exception.
- **Fix:** Add an explicit `DB.ready?/0` check (or `Ecto.Adapters.SQL.query!/2` with a lightweight probe) before calling the data functions. Return `{:ok, result}` / `{:error, :not_ready}` tuples from the lowest-level callers and handle them upstream. Only `rescue` for truly unexpected DB errors.
- **Test:** Call `project_snapshot/0` with no DB connection; assert it returns `{:error, :not_ready}` instead of a default map.

---

## Medium Severity

### CSM-011 — No URL State / Deep Linking
- **File:** `lib/bds/desktop/shell_live.ex`, `lib/bds/desktop/router.ex`
- **What:** Tabs, filters, and selected items are never reflected in the URL. No `handle_params/3` or `push_patch/2` is used anywhere in the codebase.
- **Why it's bad:** Users cannot bookmark or use the back button. Harder to debug.
- **Mitigating factor:** This is a desktop app (wx container), not a web app. URL-based navigation is less critical but still valuable for debuggability and for when the app is accessed via a browser during development.
- **Fix:** Add `handle_params/3` for at least `?tab=` and `?view=` params. Use `push_patch` on state changes.
- **Test:** Click a tab; assert the URL updates to `/?tab=posts`; refresh; assert the same tab is active.

---

### CSM-012 — Desktop File Dialog Blocks Event Handler
- **File:** `lib/bds/desktop/shell_live/sidebar_create.ex:44-69`
- **What:** `FilePicker.choose_file/1` is called directly inside `handle_event`.
- **Why it's bad:** Can freeze the socket process while the native dialog is open.
- **Mitigating factor:** In a desktop app, the user flow naturally waits for the dialog result. The risk is low in practice.
- **Fix:** Spawn a short-lived `Task` or use Desktop library's non-blocking async APIs.
- **Test:** Trigger a file picker; send another event immediately; assert the second event is handled within 100ms.

---

### CSM-013 — Bang Functions in Rendering Pipelines
- **Files:** `lib/bds/rendering/post_rendering.ex:151`, `lib/bds/rendering/filters.ex:125,127`, `lib/bds/rendering/template_selection.ex:92,102`
- **What:** `Jason.encode!`, `Liquex.parse!`, `Liquex.render!` crash on bad data instead of returning errors.
- **Fix:** Use non-bang variants, wrap in `case`, and propagate `{:error, reason}` to the caller.
- **Test:** Feed a template with a syntax error; assert the renderer returns `{:error, _}` rather than raising.

---

### CSM-014 — O(n²) Loops from `length/1` Inside Iteration
- **Files:**
  - `lib/bds/publishing.ex:127` — `length(targets)` inside `Enum.reduce_while` (typically 3 targets, negligible impact)
  - `lib/bds/rendering/list_archive.ex:299` — `index < length(grouped_blocks) - 1` inside `Enum.map`
  - `lib/bds/generation/outputs.ex:216,230,232` — repeated `length(paginated_posts)` and `length(posts)` inside comprehensions
  - `lib/bds/ui/sidebar.ex:556-565` — `acc.draft ++ [post]` in `Enum.reduce` (also covered by CSM-024)
- **Note:** In `publishing.ex` the O(n²) is negligible (3 targets). The real impact is in `outputs.ex` and `list_archive.ex` with large post sets.
- **Fix:** Bind `total = length(list)` before the loop. For `acc ++ [item]`, use reverse-accumulate + `Enum.reverse`.
- **Test:** Run the function with a list of 1,000 items; assert it completes in linear time.

---

### CSM-015 — Missing DB Indexes on Foreign Keys
- **Files:** `priv/repo/migrations/20260423120000_create_persistence_contract.exs`
- **What:** The initial migration uses `references(...)` which creates FK constraints but does NOT create dedicated indexes for most FKs. Missing indexes on:
  - `media.project_id` (queried in every sidebar/dashboard load)
  - `post_media.post_id`, `post_media.media_id`
  - `chat_messages.conversation_id`
  - `embedding_keys.post_id`, `embedding_keys.project_id`
  - `dismissed_duplicate_pairs.project_id`
  - `import_definitions.project_id`
  - `db_notifications.entity_type`, `db_notifications.entity_id`
  - `posts.status`, `posts.published_at`, `posts.language` — frequently filtered columns
- **Note:** SQLite is more forgiving than PostgreSQL for missing FK indexes, but with growing data the query plans will degrade.
- **Fix:** Add a new migration with `create index` for every foreign key and frequently filtered column.
- **Test:** Verify with `sqlite3` `EXPLAIN QUERY PLAN` that key lookups use indexes.

---

### CSM-016 — String Concatenation for Paths
- **Files:**
  - `lib/bds/rendering/metadata.ex:43` — `"/#{slug}/"`
  - `lib/bds/rendering/metadata.ex:112` — `prefix <> "/"`
  - `lib/bds/publishing.ex:284` — `String.trim_trailing(path, "/") <> "/"`
  - `lib/bds/rendering/file_system.ex:29` — `normalized_path <> ".liquid"`
  - `lib/bds/rendering/links_and_languages.ex` — path construction with `<>`
- **Fix:** Use `Path.join/1-2` and `Path.extname` / `Path.rootname`. For `"/#{slug}/"`, use `Path.join(["/", slug])` or `"/" <> slug <> "/"` → `URI.encode(slug)` is already used elsewhere.
- **Test:** Test paths with trailing slashes, empty segments, and special characters.

---

### CSM-017 — `send(self(), ...)` Component Chatter
- **Files:** 25+ call sites across editor components:
  - `lib/bds/desktop/shell_live/script_editor.ex` (3 sends)
  - `lib/bds/desktop/shell_live/post_editor.ex` (2 sends)
  - `lib/bds/desktop/shell_live/template_editor.ex` (3 sends)
  - `lib/bds/desktop/shell_live/media_editor.ex` (2 sends)
  - `lib/bds/desktop/shell_live/chat_editor.ex` (1 send)
  - `lib/bds/desktop/shell_live/menu_editor.ex` (1 send)
  - `lib/bds/desktop/shell_live/settings_editor.ex` (2 sends)
  - `lib/bds/desktop/shell_live/misc_editor.ex` (4 sends)
  - `lib/bds/desktop/shell_live/tags_editor.ex` (2 sends)
  - `lib/bds/desktop/shell_live/import_editor.ex` (1 send)
  - `lib/bds/desktop/shell_live/overlay_manager.ex` (3 sends)
  - `lib/bds/desktop/main_window.ex` (1 send)
- **What:** Components send messages to the parent via `send(self(), ...)`, forcing a broad `handle_info` in `ShellLive`. Each message type must be handled in the parent, creating tight coupling.
- **Fix:** Prefer `Phoenix.LiveView.send_update/2` for targeted component updates, or delegate through a single dispatch module that translates actions into specific state changes.
- **Test:** Refactor one component; assert it no longer uses `send(self(), ...)`.

---

## Low Severity / Code Quality

### CSM-018 — `@moduledoc false` Epidemic
- **Files:** `lib/bds/i18n.ex`, `lib/bds/map_utils.ex`, `lib/bds/bounded_atoms.ex`, `lib/bds/document_fields.ex`, `lib/bds/import_definitions.ex`, `lib/bds/publishing.ex`, `lib/bds/settings.ex`, `lib/bds/templates.ex`, `lib/bds/ai.ex`, `lib/bds/mcp.ex`, `lib/bds/scripting/capabilities.ex`, `lib/bds/scripting/api_docs.ex`
- **Fix:** Write `@moduledoc` descriptions for all public modules. Keep internal helpers documented or mark them `@moduledoc false` only if truly private.

---

### CSM-019 — Missing `@spec` on Public Functions
- **Files:** Widespread across rendering, generation, publishing, UI, and scripting modules.
- **Fix:** Add `@spec` to every public function. This is a Dialyzer prerequisite (the project already runs Dialyzer; the report notes it should be clean).

---

### CSM-020 — Deeply Nested `case` Instead of `with`
- **Files:** `lib/bds/import_definitions.ex:54-66`, `lib/bds/publishing.ex:47-58`, `lib/bds/templates.ex:86-163`
- **Fix:** Flatten with `with`:
  ```elixir
  with {:ok, record} <- Repo.get(Model, id),
       {:ok, updated} <- Repo.update(changeset) do
    {:ok, updated}
  else
    nil -> {:error, :not_found}
    {:error, changeset} -> {:error, changeset}
  end
  ```

---

### CSM-021 — `cond` Where Pattern Matching Suffices
- **Files:** `lib/bds/ai.ex:62-70`, `lib/bds/scripting/api_docs.ex:1345-1398`, `lib/bds/scripting/api_docs.ex:1433-1447`
- **Fix:** Replace `cond do x == nil -> ...; true -> ... end` with multiple function-head clauses.

---

### CSM-022 — Silent Error Swallowing
- **File:** `lib/bds/scripting.ex:64-66`
- **What:** `execute_macro/4` returns `{:ok, ""}` on `{:error, _reason}` with no logging. The caller cannot distinguish success from failure.
- **Fix:** Return the actual error tuple or at least log the failure with `Logger.error/1`.

---

### CSM-023 — SRP Violations
- **Files:**
  - `lib/bds/templates.ex:86-163` — `update_template/2` does slug changes, content changes, status transitions, file paths, transactions, cascades, and filesystem sync.
  - `lib/bds/scripting/capabilities.ex:22-248` — `for_project/2` returns a 200+ line map literal.
- **Fix:** Decompose into smaller private pipelines or domain-specific builder functions.

---

### CSM-024 — `Enum.reduce` with `acc.draft ++ [post]` (O(n²))
- **File:** `lib/bds/ui/sidebar.ex:556-565`
- **Fix:** Use `Enum.group_by/3` or reverse-accumulate and `Enum.reverse`.

---

### CSM-025 — Hardcoded Language Prefixes
- **File:** `lib/bds/generation/pagefind.ex:48-54`
- **What:** `["de/", "fr/", "it/", "es/"]` hardcoded instead of derived from project settings.
- **Fix:** Derive from project settings (`mainLanguage` and supported languages).

---

### CSM-026 — TOCTOU Race Condition in Template File System
- **File:** `lib/bds/rendering/file_system.ex:28-37`
- **What:** `Enum.find(&File.regular?/1)` checks existence, then the file is read later (in the `Liquex.FileSystem` impl, Z. 43-49). Between check and read the file can vanish.
- **Fix:** Just try to read and handle `{:error, :enoent}`. Remove the `Enum.find` existence check and attempt reads directly.

---

### CSM-027 — `if result == :ok` Instead of Pattern Matching
- **File:** `lib/bds/templates.ex:445`
- **Fix:** Use `case result do :ok -> ...; _ -> ... end`.

---

### CSM-028 — Broad `rescue` Swallowing Template Errors
- **File:** `lib/bds/rendering/filters.ex:130-132`
- **What:** `rescue _error -> ""` swallows all macro template failures silently.
- **Fix:** Rescue only specific exceptions, or return `{:error, exception}` and let the caller decide.

---

### CSM-029 — `length/1` in Guards or Comparisons
- **Files:** `lib/bds/generation/outputs.ex`, `lib/bds/ui/sidebar.ex`
- **What:** `length(list)` is O(n). Using it inside a loop makes the whole loop O(n²).
- **Fix:** Bind the length before the loop.

---

### CSM-030 — Unchecked `File.mkdir_p` / `File.mkdir_p!`
- **Files:** `lib/bds/media/thumbnails.ex:133`, `lib/bds/media/sidecars.ex:24,56`, `lib/bds/release_packaging.ex:80,85`
- **What:** Result of `File.mkdir_p/1` is discarded. `File.mkdir_p!/1` in `release_packaging` can crash on permission errors.
- **Fix:** Pattern-match `File.mkdir_p/1` or use `with`; replace bang variants with non-bang and handle errors.

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

- [ ] All critical items (CSM-001 to CSM-005) have been addressed or explicitly deferred with justification.
- [ ] All high-severity items (CSM-006 to CSM-010) have been addressed.
- [ ] CSM-001 fix covers ALL 6 affected files, not just `import_definitions.ex`.
- [ ] CSM-003 fix covers ALL `Repo.delete!` call sites (posts, tags, scripts, media, projects, templates, translations).
- [ ] CSM-007 decomposition is the prerequisite for fixing CSM-008 (render-path queries).
- [ ] Tests were written **before** implementation changes (Red → Green → Refactor).
- [ ] Full test suite passes: `mix test`.
- [ ] Dialyzer passes cleanly: `mix dialyzer` (zero warnings).
- [ ] Build succeeds: `mix compile`.
- [ ] No external JS/CSS referenced in preview/generated HTML (per AGENTS.md).
- [ ] All UI strings use gettext / i18n, no hardcoded text.
- [ ] API docs (`API.md`) updated if any API changes were made.
- [ ] Metadata diff tool and rebuild-from-database updated if metadata changed.
- [ ] Specs in `specs/` folder updated and validated if behavior changed.
- [ ] Unused code (including tests for removed features) has been deleted.
- [ ] This `CODESMELL.md` updated: fixed items removed, new ones added.
