# bDS2 Elixir Anti-Pattern & Best-Practice Audit

> Generated: 2026-05-05
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
- **File:** `lib/bds/import_definitions.ex:98-108`
- **What:** `atomize_keys/1` calls `String.to_atom(key)` on all JSON keys from user-controlled import data.
- **Why it's bad:** Atoms are never garbage-collected. A malicious import can exhaust the ~1M atom limit and crash the VM.
- **Fix:** Use `String.to_existing_atom/1` or keep keys as strings. Add a test with a JSON payload containing 100k unique string keys to verify it no longer creates atoms.
- **Related:** Also check `lib/bds/bounded_atoms.ex` for any runtime `String.to_atom` on external data.

---

### CSM-002 — Search Loads Entire Tables into Memory
- **File:** `lib/bds/search.ex:111-149`
- **What:** `search_posts/3` and `search_media/3` load **all** candidate IDs, then **all** matching records, filter in Elixir, and slice.
- **Why it's bad:** For a project with thousands of posts, every search fetches the entire table into the BEAM process.
- **Fix:** Push pagination, filtering, and sorting into SQL (`limit`, `offset`, `where`). Use `Repo.aggregate` for counts.
- **Test:** Create a project with 5,000 posts; run a search; assert memory stays below 50MB and query completes in <200ms.

---

### CSM-003 — Non-Atomic Side Effects in Post CRUD
- **File:** `lib/bds/posts.ex`
- **What:** `create_post/1`, `update_post/2`, `publish_post/1`, `delete_post/1` mix DB writes with filesystem/search/embeddings side effects.
- **Why it's bad:** If a side effect fails, the DB is already committed and the system is inconsistent. `delete_post/1` deletes files/embeddings **before** the DB row, so if `Repo.delete!` raises, the files are gone but the row remains.
- **Fix:**
  - Use `Repo.transaction` or `Ecto.Multi` to group DB + side effects atomically.
  - Use non-bang `Repo.delete/1` and return `{:error, _}` tuples.
  - Delete files **after** the DB delete succeeds, or roll back on file-delete failure.
- **Test:** Mock a file-delete failure in `delete_post/1`; assert the post row still exists.

---

### CSM-004 — Blocking `init/1` + Broken `trap_exit` in Job Runner
- **File:** `lib/bds/scripting/job_runner.ex:28-35`
- **What:**
  1. Synchronous `GenServer.call` to `JobStore.attach_runner/2` inside `init/1` blocks the supervisor.
  2. `Process.flag(:trap_exit, true)` is set but there is **no** `terminate/2` and **no** `{:EXIT, ...}` handler.
- **Why it's bad:**
  - Supervisor child startup hangs if `JobStore` is slow.
  - Dead runner PIDs leak in `JobStore.runners`, causing future `GenServer.call` timeouts.
- **Fix:**
  - Move `attach_runner` to `handle_continue/2`.
  - Remove `trap_exit` (the task uses `async_nolink`, so links aren't the issue) OR add `terminate/2` to call `JobStore.detach_runner/2`.
- **Test:** Start a runner, stop it, assert `JobStore.list_runners()` does not contain the dead PID.

---

### CSM-005 — Client-Side Filtering of Entire Tables
- **Files:** `lib/bds/ui/sidebar.ex`, `lib/bds/tags.ex`, `lib/bds/ui/dashboard.ex`
- **What:**
  - `UI.Sidebar.list_posts/1` loads every post for a project, then filters in Elixir (`apply_post_filters`).
  - `Tags.posts_with_tag/2` / `post_tag_names/1` load all posts to extract tags.
  - `UI.Dashboard.snapshot/1` loads ALL posts and ALL media for counts.
- **Why it's bad:** O(n) memory usage for the whole table, scales linearly with blog size.
- **Fix:** Move filtering, pagination, and aggregation into Ecto queries (`where`, `group_by`, `limit`, `Repo.aggregate`).
- **Test:** Create 10,000 posts; open the sidebar; assert the LiveView process memory stays bounded.

---

## High Severity

### CSM-006 — N+1 Queries in Reindexing & Rendering
- **Files:** `lib/bds/search.ex:166-177`, `lib/bds/rendering/list_archive.ex:181`, `lib/bds/rendering/post_rendering.ex:21`
- **What:**
  - `Search.reindex_posts/1` calls `insert_post_index/1` inside `Enum.each`; that helper queries `post_translations/1` per post.
  - Same pattern for media reindexing.
  - `ListArchive` and `PostRendering` call `load_post_record/1` per-post inside `Enum.map`.
- **Fix:** Preload translations in a single query before the loop, or batch-insert with a multi-insert statement.
- **Test:** Reindex 100 posts; assert the total query count is <5 (use `Ecto.Adapters.SQL.query!/2` hook or logger capture).

---

### CSM-007 — Monolithic State Rebuild ("God Function")
- **File:** `lib/bds/desktop/shell_live.ex:554-616`
- **What:** `reload_shell/2` rebuilds sidebar, dashboard, git badge, tasks, status bar, tab meta, and panel data on almost every event.
- **Why it's bad:** Even a simple sidebar toggle triggers 5+ unrelated DB queries.
- **Fix:** Decompose into focused updaters:
  - `refresh_sidebar/2`
  - `refresh_dashboard/2`
  - `refresh_git_badge/2`
  - `refresh_task_status/2`
  Only call the relevant one from each `handle_event`.
- **Test:** Toggle sidebar; assert no dashboard or git queries are executed.

---

### CSM-008 — DB Queries During Render Path
- **Files:** `lib/bds/desktop/shell_live/panel_renderer.ex`, `lib/bds/desktop/shell_live/tab_helpers.ex`
- **What:**
  - `post_link_entries/1` calls `PostLinks.list_incoming_links/1` and `Posts.get_post/1` during render.
  - `git_log_entries/1` calls `Git.file_history/2` during render.
  - `tab_helpers.ex` queries posts/media from within `derived_tab_meta/1`.
- **Fix:** Move all data fetching into event handlers (`handle_event`, `handle_params`) or the decomposed `reload_shell` updaters. Render should be a pure function of assigns.
- **Test:** Render a panel 10 times; assert no DB queries fire on re-renders.

---

### CSM-009 — Thumbnail Generation Blocks Scheduler
- **File:** `lib/bds/media/thumbnails.ex:107-165`
- **What:** `Image.open`, `Image.thumbnail!`, `Image.write!` run CPU-intensive image decode/encode in the current process.
- **Why it's bad:** Blocks the BEAM scheduler; the entire app freezes for large images.
- **Fix:** Run in `Task.async` / `Task.await` or a `Task.Supervisor` worker pool. Also handle `File.mkdir_p` result.
- **Test:** Generate a thumbnail from a 20MB image; assert the total scheduler-blocking time is <50ms (use `:erlang.system_info(:scheduler_wall_time)`).

---

### CSM-010 — `rescue` for Control Flow in Data Layer
- **File:** `lib/bds/desktop/shell_data.ex:64-74, 81-103`
- **What:** `rescue Exqlite.Error`, `rescue DBConnection.OwnershipError` to return empty defaults.
- **Why it's bad:** Exceptions are for exceptional conditions, not expected states like "DB not ready yet."
- **Fix:** Return `{:ok, _}` / `{:error, _}` tuples from the lowest-level callers and handle them upstream.
- **Test:** Call `project_snapshot/0` with no DB connection; assert it returns `{:error, _}` instead of an empty map.

---

## Medium Severity

### CSM-011 — No URL State / Deep Linking
- **File:** `lib/bds/desktop/shell_live.ex`, `lib/bds/desktop/router.ex`
- **What:** Tabs, filters, and selected items are never reflected in the URL. No `handle_params/3` or `push_patch/2` is used.
- **Why it's bad:** Users cannot bookmark or use the back button. Harder to debug.
- **Fix:** Add `handle_params/3` for at least `?tab=` and `?view=` params. Use `push_patch` on state changes.
- **Test:** Click a tab; assert the URL updates to `/?tab=posts`; refresh; assert the same tab is active.

---

### CSM-012 — Memory Pressure from Large Assigns
- **File:** `lib/bds/desktop/shell_live.ex`
- **What:** Output entries, sidebar lists, media lists, and post lists live forever in socket assigns.
- **Fix:** Use `temporary_assigns` for append-only or large lists:
  ```elixir
  socket = stream(socket, :posts, posts)
  # or
  socket = assign(socket, :output_entries, output_entries, temporary: true)
  ```
- **Test:** Load 1,000 sidebar items; assert socket assigns size stays below 100KB.

---

### CSM-013 — Desktop File Dialog Blocks Event Handler
- **File:** `lib/bds/desktop/shell_live/sidebar_create.ex:44-69`
- **What:** `FilePicker.choose_file/1` is called directly inside `handle_event`.
- **Why it's bad:** Can freeze the socket process while the native dialog is open.
- **Fix:** Spawn a short-lived `Task` or use Desktop library's non-blocking async APIs.
- **Test:** Trigger a file picker; send another event immediately; assert the second event is handled within 100ms.

---

### CSM-014 — Bang Functions in Rendering Pipelines
- **Files:** `lib/bds/rendering/post_rendering.ex:151`, `lib/bds/rendering/filters.ex:125`, `lib/bds/rendering/template_selection.ex:102`
- **What:** `Jason.encode!`, `Liquex.parse!`, `Liquex.render!` crash on bad data instead of returning errors.
- **Fix:** Use non-bang variants, wrap in `case`, and propagate `{:error, reason}` to the caller.
- **Test:** Feed a template with a syntax error; assert the renderer returns `{:error, _}` rather than raising.

---

### CSM-015 — O(n²) Loops
- **Files:**
  - `lib/bds/publishing.ex:127` — `length(targets)` inside `Enum.reduce_while`
  - `lib/bds/rendering/list_archive.ex:299` — `index < length(grouped_blocks) - 1` inside `Enum.map`
  - `lib/bds/generation/outputs.ex:208-323` — repeated `length(posts)` inside comprehensions
- **Fix:** Bind `total = length(list)` outside the loop.
- **Test:** Run the function with a large list; assert it completes in linear time.

---

### CSM-016 — Missing `@derive Jason.Encoder` on Schemas
- **Files:** All schema modules (`Post`, `Media`, `Tag`, `Template`, `Script`, `Project`, `Setting`, `ChatMessage`, `ChatConversation`, `Embedding.Key`, etc.)
- **What:** No JSON derivation. Passing a struct to `Jason.encode!/1` crashes.
- **Fix:** Add to schemas that cross API boundaries:
  ```elixir
  @derive {Jason.Encoder, except: [:__meta__]}
  schema "posts" do
  ```
- **Test:** Encode each schema struct to JSON; assert success.

---

### CSM-017 — Missing DB Indexes on Foreign Keys
- **Files:** `priv/repo/migrations/`
- **What:** Many FKs lack dedicated indexes: `media.project_id`, `post_media.post_id`, `post_media.media_id`, `chat_messages.conversation_id`, `embedding_keys.post_id`, `embedding_keys.project_id`, `publish_jobs.project_id`, etc.
- **Fix:** Add `create index` for every foreign key and frequently filtered column (`posts.status`, `posts.published_at`, `posts.language`).
- **Test:** Verify with `sqlite3` `.indexes` or Ecto introspection.

---

### CSM-018 — Missing `on_delete` in Schema Associations
- **Files:** Most schema modules
- **What:** `belongs_to` and `has_many` lack `on_delete` at the Ecto schema level.
- **Why it's bad:** Ecto preloads and reflection behave differently; cascading deletes may not work as expected at the application level.
- **Fix:** Add `on_delete: :delete_all` / `:nilify_all` to match the DB-level constraints in migrations.

---

### CSM-019 — String Concatenation for Paths
- **Files:** `lib/bds/rendering/metadata.ex`, `lib/bds/rendering/links_and_languages.ex`, `lib/bds/publishing.ex`, `lib/bds/rendering/file_system.ex:29`
- **What:** `"/#{slug}/"`, `String.trim_trailing(path, "/") <> "/"`, `normalized_path <> ".liquid"`
- **Fix:** Use `Path.join/1-2` and `Path.extname` / `Path.rootname`.

---

### CSM-020 — `send(self(), ...)` Component Chatter
- **Files:** `lib/bds/desktop/shell_live/script_editor.ex`, `lib/bds/desktop/shell_live/chat_editor.ex`, `lib/bds/desktop/shell_live/overlay_manager.ex`
- **What:** Components send messages to the parent via `send(self(), ...)`, forcing a broad `handle_info` in `ShellLive`.
- **Fix:** Prefer `Phoenix.LiveView.send_update/2` for targeted updates, or delegate through a single dispatch module.

---

## Low Severity / Code Quality

### CSM-021 — `@moduledoc false` Epidemic
- **Files:** `lib/bds/i18n.ex`, `lib/bds/map_utils.ex`, `lib/bds/bounded_atoms.ex`, `lib/bds/document_fields.ex`, `lib/bds/import_definitions.ex`, `lib/bds/publishing.ex`, `lib/bds/settings.ex`, `lib/bds/templates.ex`, `lib/bds/ai.ex`, `lib/bds/mcp.ex`, `lib/bds/scripting/capabilities.ex`, `lib/bds/scripting/api_docs.ex`
- **Fix:** Write `@moduledoc` descriptions for all public modules. Keep internal helpers documented or mark them `@moduledoc false` only if truly private.

---

### CSM-022 — Missing `@spec` on Public Functions
- **Files:** Widespread across rendering, generation, publishing, UI, and scripting modules.
- **Fix:** Add `@spec` to every public function. This is a Dialyzer prerequisite (the project already runs Dialyzer; the report notes it should be clean).

---

### CSM-023 — Deeply Nested `case` Instead of `with`
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

### CSM-024 — `cond` Where Pattern Matching Suffices
- **Files:** `lib/bds/ai.ex:62-70`, `lib/bds/scripting/api_docs.ex:1345-1398`, `lib/bds/scripting/api_docs.ex:1433-1447`
- **Fix:** Replace `cond do x == nil -> ...; true -> ... end` with multiple function-head clauses.

---

### CSM-025 — Silent Error Swallowing
- **File:** `lib/bds/scripting.ex:64-66`
- **What:** Macro execution errors return `{:ok, ""}` with no logging.
- **Fix:** Return the actual error tuple or at least log the failure with `Logger.error/1`.

---

### CSM-026 — Missing `terminate/2` in Stateful GenServers
- **Files:** `lib/bds/scripting/job_runner.ex`, `lib/bds/scripting/job_store.ex`
- **Fix:** Add `terminate/2` to clean up runner mappings, timers, or temporary resources.

---

### CSM-027 — SRP Violations
- **Files:**
  - `lib/bds/templates.ex:86-163` — `update_template/2` does slug changes, content changes, status transitions, file paths, transactions, cascades, and filesystem sync.
  - `lib/bds/scripting/capabilities.ex:22-248` — `for_project/2` returns a 200+ line map literal.
- **Fix:** Decompose into smaller private pipelines or domain-specific builder functions.

---

### CSM-028 — `Enum.reduce` with `acc.draft ++ [post]` (O(n²))
- **File:** `lib/bds/ui/sidebar.ex:556-565`
- **Fix:** Use `Enum.group_by/3` or reverse-accumulate and `Enum.reverse`.

---

### CSM-029 — Hardcoded Language Prefixes
- **File:** `lib/bds/generation/pagefind.ex:48-54`
- **What:** `["de/", "fr/", "it/", "es/"]` hardcoded.
- **Fix:** Derive from project settings (`mainLanguage` and supported languages).

---

### CSM-030 — TOCTOU Race Condition in Template File System
- **File:** `lib/bds/rendering/file_system.ex:28-37`
- **What:** `Enum.find(&File.regular?/1)` checks existence, then the file is read later. Between check and read the file can vanish.
- **Fix:** Just try to read and handle `{:error, :enoent}`.

---

### CSM-031 — `if result == :ok` Instead of Pattern Matching
- **File:** `lib/bds/templates.ex:445`
- **Fix:** Use `case result do :ok -> ...; _ -> ... end`.

---

### CSM-032 — Broad `rescue` Swallowing Template Errors
- **File:** `lib/bds/rendering/filters.ex:130-132`
- **What:** `rescue _error -> ""` swallows all macro template failures silently.
- **Fix:** Rescue only specific exceptions, or return `{:error, exception}` and let the caller decide.

---

### CSM-033 — `length/1` in Guards or Comparisons
- **Files:** `lib/bds/generation/outputs.ex`, `lib/bds/ui/sidebar.ex`
- **What:** `length(list)` is O(n). Using it inside a loop makes the whole loop O(n²).
- **Fix:** Bind the length before the loop.

---

### CSM-034 — Unchecked `File.mkdir_p` / `File.mkdir_p!`
- **Files:** `lib/bds/media/thumbnails.ex:133`, `lib/bds/media/sidecars.ex:24,56`, `lib/bds/release_packaging.ex:80,85`
- **What:** Result of `File.mkdir_p/1` is discarded. `File.mkdir_p!/1` in `release_packaging` can crash on permission errors.
- **Fix:** Pattern-match `File.mkdir_p/1` or use `with`; replace bang variants with non-bang and handle errors.

---

### CSM-035 — `try/rescue` Instead of `with` and Error Tuples
- **Files:** `lib/bds/rendering/filters.ex`, `lib/bds/templates.ex`, `lib/bds/desktop/shell_data.ex`
- **Fix:** Replace `try/rescue` around expected failures with non-bang functions and `with` chains.

---

### CSM-036 — `Map.get` with Default Instead of Pattern Matching
- **Files:** Widespread
- **What:** `Map.get(map, key, default)` when the key is expected to exist.
- **Fix:** Use pattern matching (`%{key: value} = map`) or `Map.fetch!/2` if the key is required.

---

### CSM-037 — `Enum.each` with Side Effects That Should Be `Enum.map` / Comprehensions
- **Files:** `lib/bds/search.ex:174-177`, `lib/bds/embeddings.ex`
- **What:** `Enum.each` used for inserting records. The side-effect pattern is fine, but `Enum.map` + `Repo.insert_all` would be much faster for bulk inserts.
- **Fix:** Use `Repo.insert_all` for batch inserts instead of `Enum.each` + `Repo.insert`.

---

### CSM-038 — `File.read!` / `File.write!` Without Error Handling
- **Files:** `lib/bds/preview_assets.ex:32`, `lib/bds/release_packaging.ex:105`, `lib/bds/templates.ex:488-489`
- **Fix:** Use `File.read/1`, `File.write/2`, and handle `{:error, reason}`.

---

### CSM-039 — Process Dictionary (`Process.get/put`) Usage
- **Files:** Check `lib/bds/desktop/menu_bar.ex:25-34`, any other `Process.put`
- **What:** `UILocale.put/1` sets process dictionary in the MenuBar process.
- **Fix:** This is isolated to the MenuBar process so it's low-risk, but document it explicitly.

---

### CSM-040 — Missing `@impl true` on GenServer Callbacks
- **File:** `lib/bds/publishing.ex:46,61,71,75`
- **Fix:** Add `@impl true` before every `handle_call`, `handle_cast`, `handle_info`, and `terminate`.

---

## Checklist for Agents Picking Up This File

- [ ] All critical items (CSM-001 to CSM-005) have been addressed or explicitly deferred with justification.
- [ ] All high-severity items (CSM-006 to CSM-010) have been addressed.
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
