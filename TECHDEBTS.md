# Technical Debt Backlog

Findings from a full codebase + stack review (2026-06-11) covering BEAM/OTP
antipatterns, build-vs-buy decisions, and architecture. Tasks are ordered in
phases that make sense to execute sequentially; within a phase, tasks are
independent unless noted. Phase 1 contains the top five findings.

## How to work these tasks

Every task must follow the project rules in `AGENTS.md`:

- **Test-first**: write a failing test before the fix, against the real module.
- **Clean gates**: `mix compile --warnings-as-errors`, full `mix test`
  (use `xvfb-run mix test` on headless Linux), and `mix dialyzer` must all pass.
- **Delete dead code completely** — no commented-out remnants.
- **Specs**: check `specs/` for an allium spec covering the touched area; if the
  spec changes, validate it with `allium check <file>` (must exit 0).
- **No new CDN/external assets** in preview or generated HTML.
- New user-facing strings go through gettext with translations for de/fr/it/es.
- If a task touches an app API surface, update the script bridge and `API.md`
  in the same change.

Each task lists: context (why it matters), affected files, suggested approach,
and acceptance criteria. Re-verify line numbers before editing — they reflect
the review snapshot (commit `bf93403`).

---

## Phase 1 — Top five (security & correctness)

### TD-01: Move the AI secret encryption key out of the repo ✅ DONE (2026-06-11)

**Severity: High (security).**

**Status: implemented.** `BDS.AI.SecretKey` resolves the master key from the
macOS Keychain (`security` CLI) with a 0600 key-file fallback under the
private app dir; the deterministic node-name fallback is gone (operations
return `{:error, :secret_key_unavailable}`); `BDS.AI.SecretMigration`
re-encrypts legacy rows at every boot from `BDS.RepoBootstrap`; the endpoint
`secret_key_base` is generated per boot. The legacy repo key literal remains
in `SecretBackend`/tests **only** to decrypt and migrate existing user
databases — remove it together with `SecretMigration` in a future release.
The test env pins a deterministic `:ai_secret_key` in `config/test.exs` so
the suite never touches the keyring; that string protects nothing.
Rode along (mandated clean-gates): fixed all 10 pre-existing compiler type
warnings surfaced by the full recompile and the one dialyzer finding
(MapSet opacity in `mac_bundle/dylibs.ex`), so `mix compile
--warnings-as-errors --force` and `mix dialyzer` are now clean baselines.

**Context.** `BDS.AI.SecretBackend` encrypts AI provider API keys at rest with
AES-256-GCM, but the key is the hardcoded string in `config/config.exs`
(`config :bds, :ai_secret_key, "bds_desktop_shell_secret_key_base_..."`), which
is committed to the repository and **never overridden in
`config/runtime.exs`**, so production uses it too. Anyone with the user's
SQLite database file plus the public source can decrypt their API keys. The
fallback path is worse: `sha256(Atom.to_string(node()) <> ":bds:ai")`, and the
node name is effectively always `nonode@nohost`, making the fallback key a
constant. The same hardcoded string also serves as the prod `secret_key_base`
for `BDS.Desktop.Endpoint`.

**Files.**
- `lib/bds/ai/secret_backend.ex` (`secret_key/0`, lines ~35–41)
- `config/config.exs` (lines ~22–26: `:desktop` secret_key_base and `:ai_secret_key`)
- `config/runtime.exs` (no override exists today)

**Approach.**
1. On macOS, store the key in the Keychain via `System.cmd("security", ["add-generic-password", ...])` /
   `find-generic-password`. On other platforms (and as a portable fallback),
   generate a random 32-byte key on first launch and persist it with `0600`
   permissions under the app's private data dir (`~/Library/Application
   Support/bds` on macOS — see project conventions; never the repo or the
   project.json folder).
2. Remove the deterministic node-name fallback entirely; if no key can be
   obtained, fail loudly rather than silently degrade to obfuscation.
3. Migration: on startup, if secrets were encrypted with the legacy hardcoded
   key, decrypt with the old key and re-encrypt with the new one (one-time,
   then remove legacy key knowledge in a follow-up release).
4. Generate the endpoint `secret_key_base` at runtime (random per boot is fine
   for a loopback-only desktop endpoint) instead of shipping it in config.

**Acceptance.** No secret material in the repo; `grep -r "secret_key_base_64\|ai_secret_key" config/` shows no literal keys; existing encrypted secrets still decrypt after upgrade (covered by a migration test); SecretBackend tests cover missing-key failure mode.

---

### TD-02: Replace the hand-rolled `:httpc` client with Req

**Severity: High (reliability), enables TD-06 (streaming).**

**Context.** `BDS.AI.HttpClient` wraps `:httpc` with empty http options — the
default timeout is **infinity**, so a hung LLM endpoint (Ollama, LM Studio,
any OpenAI-compatible server) blocks the chat task forever (see TD-03 for the
blocking chain above it). There is no retry, no connection pooling, no pinned
TLS verification (behavior depends on the OTP version's `:httpc` defaults),
and `:inets.start()`/`:ssl.start()` are called redundantly on every request
(both are already in `extra_applications`). Req is already an optional
dependency of the `image` package, so the dependency tree barely grows.

**Files.**
- `lib/bds/ai/http_client.ex` (delete or reduce to a thin Req wrapper)
- `lib/bds/ai/openai_compatible_runtime.ex` (calls `HttpClient.get/post`)
- `lib/bds/desktop/automation.ex` (also uses `:httpc`; test-automation server, lower priority but should follow)
- `mix.exs` (add `{:req, "~> 0.5"}`)

**Approach.** Add Req with explicit `connect_options` (timeout), `receive_timeout`
(generous but finite, e.g. 120s for LLM responses; make it config-driven under
`config :bds, :ai`), `retry: :transient` for idempotent GETs only (do NOT
auto-retry chat completions), and default TLS verification. Keep the existing
`{:ok, %{status, headers, body}} | {:error, reason}` contract so the runtime
and its tests change minimally, or inject Req as the `:http_client` the way
tests already do.

**Acceptance.** No `:httpc` calls remain under `lib/bds/ai/`; a test proves a
slow/hung endpoint produces `{:error, %{kind: :http_error, reason: :timeout}}`
within the configured budget instead of hanging; dialyzer clean.

---

### TD-03: Fix `BDS.AI.InFlight` ETS ownership and creation race

**Severity: High (correctness).**

**Context.** `lib/bds/ai/in_flight.ex` creates its named ETS table lazily in
whichever process first calls `table/0`. Two defects: (1) the table is owned
by that first caller — typically a transient LiveView or chat task — so when
that process exits, the table and all in-flight chat registrations vanish,
breaking `cancel_chat/1`; (2) two concurrent first-callers race on
`:ets.new/2` with `:named_table`, and the loser crashes with `badarg`.

**Files.**
- `lib/bds/ai/in_flight.ex`
- `lib/bds/application.ex` (supervision tree)

**Approach.** Create the table from a stable owner. Simplest options:
- create it directly in `BDS.Application.start/2` (the application process
  lives for the VM's lifetime), or
- give InFlight a minimal GenServer whose `init/1` creates the table
  (`:named_table, :public, :set, read_concurrency: true`) and add it to the
  supervision tree before anything that uses chat.

Remove the lazy `table/0` creation path entirely; `register/unregister/lookup`
should assume the table exists.

**Acceptance.** A test demonstrates registrations survive the death of the
registering process; no code path calls `:ets.new` outside the owner's init;
concurrent-first-use race is impossible by construction.

---

### TD-04: Flush embedding indexes on shutdown (or delete the dead `flush_all`)

**Severity: Medium (perf/contract), High confidence.**

**Context.** App shutdown SIGKILLs the BEAM (`BDS.Desktop.Shutdown.quit/0` —
a documented and legitimate workaround for a wxWidgets static-destructor
segfault on macOS). Consequence: **no `terminate/2` callback in the whole app
ever runs on quit.** `BDS.Embeddings.Index` traps exits and relies on
`terminate/2` to persist debounced HNSW index saves, and its moduledoc
promises "force-saved on project switch / shutdown". Meanwhile
`Embeddings.Index.flush_all/0` exists but has **zero production callers**
(dead code per the AGENTS.md mandate). The lazy-reload-from-DB fallback makes
this a startup-performance bug (index rebuilt unnecessarily) rather than data
loss, but the code contradicts its own contract.

**Files.**
- `lib/bds/desktop/shutdown.ex` (`persist_safely/0`, lines ~92–99)
- `lib/bds/embeddings/index.ex` (`flush_all/0` line ~87, `terminate/2` line ~167, moduledoc)

**Approach.** Call `BDS.Embeddings.Index.flush_all()` inside
`Shutdown.persist_safely/0` next to `MainWindow.persist_now()` (same
rescue/catch hardening). Keep `terminate/2` as defense-in-depth for supervised
restarts. Audit for other state that assumed graceful shutdown (search the
tree for `terminate/2` implementations and check each one's expectations
against the SIGKILL path). If instead the decision is that lazy rebuild is the
intended behavior, delete `flush_all/0` and fix the moduledoc — pick one,
don't keep both.

**Acceptance.** Either `flush_all` is wired into the shutdown path with a test
(injectable shutdown module already exists: `:desktop_shutdown_module` env),
or it is deleted and the moduledoc no longer claims shutdown saving. No other
`terminate/2` in the codebase silently depends on graceful shutdown for
correctness.

---

### TD-05: Replace xmerl with Saxy in the WXR importer; add import transactions

**Severity: Medium-High (DoS + integrity on user-supplied files).**

**Context.** `BDS.WxrParser.parse_xml/1` uses `:xmerl_scan.string/1`, which
**creates atoms from element and attribute names** in the parsed document. WXR
files are user-supplied imports, so a malicious or merely huge/weird file can
grow the atom table (atoms are never GC'd → eventual VM crash). It also reads
the entire file into memory (`File.read!` + full DOM); real WordPress exports
reach hundreds of MB. Separately, the import/rebuild write loops run one
autocommit transaction per row on SQLite — slow (one fsync per post) and a
failure mid-way leaves a half-imported database.

**Files.**
- `lib/bds/wxr_parser.ex` (full rewrite of the parsing layer; keep the output map shape)
- `lib/bds/import_execution.ex` (line ~359: `Enum.each(post_ids, ...)` write loop)
- `lib/bds/posts/rebuild_from_files.ex` (lines ~37–56: per-file upsert loop)
- `mix.exs` (add `{:saxy, "~> 1.6"}`)

**Approach.**
1. Rewrite WxrParser on Saxy (SAX or its simple-form DOM builder). Saxy keeps
   names as binaries (no atom creation) and supports streaming via
   `Saxy.parse_stream/3` with `File.stream!`. Preserve the existing public
   contract (`parse_file/1`, `parse_xml/1` returning
   `%{site:, posts:, pages:, media:, categories:, tags:}`) so
   `import_analysis.ex`/`import_execution.ex` are untouched; the existing
   parser tests become the safety net.
   Note: `sweet_xml` is already in the dep tree via `image`, but it is
   xmerl-based and inherits the atom problem — don't use it for this.
2. Wrap import and rebuild write loops in `Repo.transaction` (chunked, e.g.
   500 rows per transaction, to keep WAL size and progress reporting sane).
   Consider `Repo.insert_all` in chunks for plain inserts — there is currently
   not a single `insert_all` in the codebase.

**Acceptance.** A test feeds XML with many unique element names and asserts
`:erlang.system_info(:atom_count)` does not grow proportionally; existing
import fixture tests pass unchanged; a failure injected mid-import leaves the
DB unchanged (rolled back chunk); large-import benchmark shows the transaction
batching speedup.

---

## Phase 2 — Unbounded blocking & cancellation

### TD-06: Real SSE streaming for chat

**Depends on TD-02 (Req).**

**Context.** `OpenAICompatibleRuntime.generate/3` never sets `"stream": true`;
the UI's `{:chat_streaming_content, ...}` event fires exactly once with the
complete response, i.e. streaming is fake. For local models this is the
single biggest perceived-latency win available.

**Files.**
- `lib/bds/ai/openai_compatible_runtime.ex`
- `lib/bds/ai/chat.ex` (`notify_chat_event` plumbing, `chat_round/9`)
- `lib/bds/desktop/shell_live/chat_editor.ex` (consume incremental events)

**Approach.** Use Req's `into:` option (fun or `:self`) to consume
`text/event-stream` chunks, parse `data:` lines incrementally, emit
`{:chat_streaming_content, conversation_id, delta}` per token-batch, and
accumulate the full message for persistence (keep persistence semantics
identical: one assistant row per round, tool_calls assembled from streamed
fragments). Gate on a config flag so non-streaming providers still work.
Remember the AGENTS.md AI rule: all automatic AI activity stays gated by
airplane mode / local model / toast.

**Acceptance.** A mock SSE server test asserts multiple incremental content
events arrive before the final `{:ok, reply}`; tool-call rounds still work;
cancellation mid-stream (TD-07) aborts the HTTP request.

### TD-07: Bound the chat await chain; end-to-end timeout & cancellation

**Context.** `BDS.AI.Chat.send_chat_message/3` blocks the caller (a LiveView
process) on a hand-rolled `await_chat_task/1` — a raw `receive` with **no
`after` clause**. Combined with the infinite HTTP timeout (TD-02) the whole
chain is unbounded. Even after TD-02, a defense-in-depth deadline belongs
here.

**Files.**
- `lib/bds/ai/chat.ex` (`send_chat_message/3` lines ~185–219, `await_chat_task/1` lines ~855–882)

**Approach.** Give `await_chat_task` an `after` deadline derived from config
(request timeout × max_tool_rounds + margin), returning
`{:error, :chat_timeout}` and terminating the task via
`Task.Supervisor.terminate_child` (the path `cancel_chat/1` already uses).
Alternatively restructure to fully async: run the chat task fire-and-forget
and deliver results to the LiveView via the existing `event_target` /
PubSub mechanism, so no process ever blocks. The async restructure is the
better end state; the `after` clause is the cheap immediate fix.

**Acceptance.** A stalled runtime stub cannot hang the caller past the
deadline; cancel during a round kills the HTTP request and leaves the
conversation in a consistent persisted state.

### TD-08: Remove test-sandbox scaffolding from production chat code

**Context.** `chat.ex` contains a `:sandbox_ready` send/receive handshake and
`allow_repo_sandbox/1` (with `Code.ensure_loaded?` + blanket `rescue`) purely
so the Ecto SQL sandbox works for the `async_nolink` chat task in tests. Since
ecto_sql 3.4 the sandbox automatically follows `$callers` for processes
spawned via `Task`/`Task.Supervisor`, making all of this unnecessary —
**verify this against the project's ecto_sql version and test modes first**
(it holds for the default `:shared`/ownership modes when the caller chain is
intact).

**Files.**
- `lib/bds/ai/chat.ex` (lines ~197–214, ~938–950)

**Approach.** Delete the handshake (`receive :sandbox_ready`, the
`send(task.pid, :sandbox_ready)`, and `allow_repo_sandbox/1`); run the full
test suite to confirm `$callers` propagation covers it. If some test setup
genuinely needs explicit allowance, move that into the test helper, not
production code.

**Acceptance.** Production module has zero sandbox references; full suite
green.

### TD-09: Graceful task cancellation in `BDS.Tasks`

**Context.** `Tasks.cancel_task/1` uses `Process.exit(pid, :kill)` — the
worker gets no chance to clean up mid-upload or mid-file-write
(`Persistence.atomic_write` mitigates file corruption but not e.g. remote
half-states). `cancel_chat` already models the right approach.

**Files.**
- `lib/bds/tasks.ex` (line ~130)
- `lib/bds/scripting/job_runner.ex` (`handle_call(:cancel, ...)` line ~67 — same pattern)

**Approach.** Use `Task.Supervisor.terminate_child/2` (delivers `:shutdown`,
escalates to kill after the child's shutdown timeout). Workers that need
cleanup can trap exits locally. Keep the state bookkeeping identical
(`:cancelled` status, queue promotion).

**Acceptance.** A test worker with `trap_exit` observes `:shutdown` and runs
its cleanup before dying; cancelled tasks still free a concurrency slot.

### TD-10: Timeouts for external `git` commands

**Context.** `BDS.Git` shells out via `System.cmd`, which has **no timeout**.
`GIT_TERMINAL_PROMPT=0` and SSH BatchMode prevent interactive hangs, but a
network-level stall on `fetch`/`pull`/`push`/`lfs` blocks the calling task
indefinitely. (Shelling out to git itself is the right call — current Elixir
libgit2 bindings are not mature; keep that decision.)

**Files.**
- `lib/bds/git.ex` (`system_runner/3` line ~343, `run_git/3`)

**Approach.** Wrap the command in `Task.async` + `Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)`
inside `system_runner` (note: the OS process may need explicit killing —
consider `MuonTrap` for proper external-process supervision, or spawn git via
a port with `:kill_group`). Default timeout config-driven: generous for
network ops (120s), short for local ops (15s). Map timeout to a structured
error like the existing `%{kind: :auth, ...}` shape so the UI can toast it.

**Acceptance.** A runner stub that sleeps past the deadline produces
`{:error, %{kind: :timeout, ...}}`; no orphaned OS processes after timeout
(test with a real `sleep` binary).

---

## Phase 3 — Process architecture (de-bottleneck singletons)

### TD-11: Move preview rendering out of the `BDS.Preview` GenServer

**Context.** Every preview HTTP request (`Preview.request/2`,
`preview_draft/3`) renders Markdown + Liquid **inside** the singleton
`BDS.Preview` GenServer via `handle_call`. A browser loading one page fires
parallel requests (page, CSS, images) that all serialize through this single
process — the textbook "process used for code organization" bottleneck.

**Files.**
- `lib/bds/preview.ex` (`handle_call({:request, ...})` line ~93, `handle_call({:preview_draft, ...})` line ~102)
- `lib/bds/preview/router.ex` (the Plug calling into Preview)

**Approach.** Keep the GenServer for what actually needs serialization
(server lifecycle: start/stop/ensure, current-project state, graceful drain).
For requests, expose a fast state read (`:sys.get_state`-free — e.g. a public
ETS table or a lightweight `handle_call(:current_project)`) and perform
rendering in the Bandit request process itself. The drain logic
(`@drain_timeout`) already tracks inflight requests — adapt it to count
renderers via monitors or a counter.

**Acceptance.** A test issues N concurrent slow renders and asserts they
overlap (wall time « N × single render); stop_preview still drains correctly.

### TD-12: Move HNSW builds and duplicate scans out of `Embeddings.Index` handle_call

**Context.** `Embeddings.Index` (singleton) builds HNSW graphs and runs full
duplicate scans inside `handle_call` with client timeout `:infinity`. A long
duplicate scan head-of-line-blocks every neighbor query the UI makes. The
state it guards (index refs, label maps, debounce timers) is small; the work
is what's big.

**Files.**
- `lib/bds/embeddings/index.ex` (`handle_call({:put, ...})` ~105, `{:duplicate_pairs, ...}` ~128)

**Approach.** For `duplicate_pairs` (read-only over the index ref): capture
the entry in the GenServer, spawn the scan in a `Task` (HNSWLib index
resources are usable from other processes — verify; they are NIF resources,
confirm thread-safety of concurrent reads in hnswlib docs), and reply via
`GenServer.reply/2`. For `put` (build): construct the graph in the caller or
a Task and hand the finished index to the GenServer for state swap +
debounced save. Queries during a rebuild keep hitting the old index.

**Acceptance.** Neighbor queries return while a duplicate scan is running
(test with a large synthetic index); debounce/flush semantics unchanged.

### TD-13: Slim down the `Publishing` GenServer call surface

**Context.** `Publishing` does Repo writes inside `handle_call`
(`:upload_site`, `:update_job`) and the uploader makes per-file synchronous
calls (`:should_upload_scp_file` / `:mark_uploaded_scp_file`) — chatty
serialization through one process during uploads.

**Files.**
- `lib/bds/publishing.ex` (lines ~45–119)

**Approach.** Job creation (Repo insert) can happen in the caller before the
call; the GenServer keeps only `scp_uploads` mtime state. Batch the mtime
check: one call returning the filtered upload list instead of two calls per
file. Consider whether `scp_uploads` state should be ETS
(`read_concurrency`) owned by the GenServer.

**Acceptance.** Upload of N files makes O(1) GenServer calls for mtime
bookkeeping, not O(N)·2; behavior identical for incremental uploads.

### TD-14: Replace polling with messaging (CliSync watcher + rebuild sequencing)

**Context.** Two polling loops:
1. `CliSync.Watcher` polls the SQLite notifications table every **100 ms
   forever** — ~10 queries/sec at idle in a battery-powered desktop app.
2. `shell_commands.ex` `wait_for_group_phase/3` sleep-polls
   `Tasks.list_tasks()` every 50 ms to sequence rebuild steps.

**Files.**
- `lib/bds/cli_sync/watcher.ex` (`@default_poll_interval_ms 100`)
- `lib/bds/desktop/shell_commands.ex` (`wait_for_group_phase/3` lines ~563–585)
- `lib/bds/tasks.ex` (add completion broadcast)

**Approach.**
1. Watcher: cheapest meaningful fix is a `PRAGMA data_version` pre-check —
   a single integer read that changes only when *another connection* commits;
   only query the notifications table when it moves. (SQLite update hooks
   don't fire for external connections, so the CLI-writes use case genuinely
   needs polling — make it near-free instead of removing it.) Alternatively
   watch the `-wal` file mtime with the `file_system` package. Also consider
   lengthening the idle interval with backoff.
2. Rebuild sequencing: have `BDS.Tasks` broadcast task terminal states on
   `BDS.PubSub` (it already sits next to PubSub in the supervision tree);
   `wait_for_group_phase` subscribes and `receive`s with a deadline instead
   of sleep-polling.

**Acceptance.** Idle app issues no table queries when `data_version` is
unchanged (or interval ≥ 1s with backoff); rebuild sequencing has no
`Process.sleep`; CLI-sync round-trip latency stays ≤ current behavior.

### TD-15: `BDS.Tasks` housekeeping (queue type, eviction timers)

**Context.** Minor inefficiencies in `tasks.ex`: the pending queue is a list
appended with `++` (O(n) per submit), and **every** finishing task schedules
a fresh 1-hour `send_after` eviction timer — timers accumulate without bound
(harmless, but sloppy).

**Files.**
- `lib/bds/tasks.ex` (`handle_call({:submit_task,...})` ~84, `schedule_finished_task_eviction/1` ~365)

**Approach.** Use `:queue` for the pending queue. Replace per-finish timers
with one periodic sweep (`send_after` rescheduled in `handle_info(:evict_finished_tasks, ...)`)
or track a single timer ref. Also consider downgrading `report_progress` from
`call` to `cast` (progress is fire-and-forget; the throttle already drops
updates).

**Acceptance.** One live eviction timer at most; queue operations O(1);
existing task lifecycle tests green.

---

## Phase 4 — Build-vs-buy replacements

### TD-16: Frontmatter robustness — yaml_elixir/ymlr or harden the hand-rolled parser

**Context.** `BDS.Frontmatter` is a hand-rolled YAML subset with concrete
bugs for user-edited files:
- `parse_document` splits on `"\n---\n"` — **CRLF files never match** and are
  rejected as `:invalid_frontmatter`. External editors on Windows will produce
  these.
- `parse_string` handles quotes by trimming the trailing quote char — a quoted
  string containing its own quote mid-string is corrupted.
- No nesting support (may be intentional).

Decision needed: adopt `yaml_elixir` (parse) + `ymlr` (emit), or keep the
subset deliberately (round-trip stability for file diffs is a legitimate
reason) and fix the bugs. Note the metadata sync rule: frontmatter is read by
publishing, metadata-diff, and rebuild-from-files — all three must stay in
agreement, which argues for keeping one serializer either way.

**Files.**
- `lib/bds/frontmatter.ex`
- Callers: `lib/bds/posts/file_sync.ex`, `lib/bds/posts/rebuild_from_files.ex`, `lib/bds/document_fields.ex`

**Approach (minimum).** Normalize `\r\n` → `\n` before parsing; rewrite
`parse_string` to properly unescape (scan, don't trim); add property-style
round-trip tests (`parse(serialize(x)) == x`) including quotes, newlines,
unicode, CRLF input. If switching to yaml_elixir: keep `serialize_document`
output byte-stable against current golden files to avoid noisy git diffs in
user projects.

**Acceptance.** CRLF fixture parses; round-trip property tests pass; golden
serialization fixtures unchanged (if keeping custom serializer).

### TD-17: Language detection via `paasaa` (optional, low priority)

**Context.** `Search.detect_language/1` uses diacritic regexes + tiny word
lists; German text without umlauts (common in short posts) falls through to
English, picking the wrong stemmer. `paasaa` is a pure-Elixir trigram
detector.

**Files.**
- `lib/bds/search.ex` (lines ~60–89, `detect_language/1`, `@language_hints`)

**Approach.** Add `{:paasaa, "~> 0.6"}`; use it for texts above a length
threshold, keep the cheap heuristics as a short-text fallback; map ISO codes
to `@stemmer_algorithms` keys; default `"en"` unchanged. Delete
`@language_hints` if fully superseded (dead-code rule).

**Acceptance.** Misclassification fixtures (umlaut-free German, accented-free
French) detect correctly; stemmer selection unchanged for English.

### TD-18: Evaluate Oban (Lite engine) for durable jobs

**Context.** Three overlapping job systems exist: in-memory UI tasks
(`BDS.Tasks`), DB-persisted publish jobs (`Publishing` + `PublishJob` rows),
and scripting jobs (`JobStore`/`JobRunner`/`JobSupervisor`). The durable ones
(publishing, possibly long script jobs) would get retries, uniqueness,
crash-recovery-on-restart, and telemetry for free from Oban's SQLite `Lite`
engine on the existing `ecto_sqlite3` setup. **This is an evaluation task,
not a mandate** — the in-memory `BDS.Tasks` UI progress system should stay.

**Files (for the evaluation).**
- `lib/bds/publishing.ex`, `lib/bds/publishing/publish_job.ex`
- `lib/bds/scripting/job_store.ex`, `job_runner.ex`, `job_supervisor.ex`
- `lib/bds/tasks.ex` (stays; would wrap Oban job progress for the UI)

**Approach.** Spike: model `upload_site` as an Oban worker with the Lite
engine; check binary-size and startup cost impact for the desktop release;
check interplay with the test sandbox and with the `bds_mcp` release. Write
up a go/no-go with the spike branch. If no-go, document why in this file and
close.

**Acceptance.** Decision documented; if go: publishing migrated first, with
crash-recovery test (kill app mid-upload, job resumes/retries on restart).

### TD-19: Add credo, mix_audit (and consider sobelow) to the quality gates

**Context.** The project enforces dialyzer + warnings-as-errors but has no
style/consistency linter and no dependency CVE audit. Cheap, high-leverage
additions.

**Files.**
- `mix.exs` (deps + `validate` alias), new `.credo.exs`

**Approach.** Add `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}`
and `{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}`. Extend the
`validate` alias: `["test", "credo --strict", "deps.audit", "dialyzer"]`.
Start credo in non-strict mode if the initial violation count is large; fix
or explicitly disable rules rather than leaving noise. Sobelow is
Phoenix-web-oriented; evaluate whether its checks add signal for a
loopback-only desktop endpoint before adopting.

**Acceptance.** `mix validate` runs all four gates clean; CI/agent
instructions (AGENTS.md) updated to mention them.

---

## Phase 5 — Consistency, config & hygiene

### TD-20: Align SQLite pool configuration between dev and prod

**Context.** Dev runs `pool_size: 5` (config.exs), prod runs `pool_size: 1`
(runtime.exs) — so dev and prod have **different concurrency semantics**: dev
can hit `SQLITE_BUSY`/interleavings prod never sees; prod serializes every
read behind every write. WAL mode + `busy_timeout: 15_000` are already set
globally.

**Files.**
- `config/config.exs` (pool_size 5), `config/runtime.exs` (POOL_SIZE default "1")

**Approach.** Pick one deliberate model and apply it to both envs. Options:
(a) pool of 1 everywhere (simplest, fully serialized, fine for single-user);
(b) modest pool (3–5) everywhere relying on WAL + busy_timeout; (c)
ecto_sqlite3's documented separate read/write pool pattern. Document the
choice in a comment. Run the suite and a manual smoke under the chosen prod
setting.

**Acceptance.** Same pool model in dev and prod; rationale comment in config;
no busy-timeout regressions in tests.

### TD-21: Harden `Persistence.atomic_write`

**Context.** `atomic_write/2` uses a fixed `path <> ".tmp"` temp name — two
concurrent writers to the same path corrupt each other's temp file before
rename. No fsync before rename (crash can leave an empty/partial target on
some filesystems); for blog-post files that durability trade-off is
defensible, but the temp-name collision is not.

**Files.**
- `lib/bds/persistence.ex` (`atomic_write/2` lines ~70–82)

**Approach.** Unique temp suffix:
`path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))`.
Optionally `:file.sync` the temp file before rename behind an opt-in flag for
critical writes. Clean up stray `*.tmp.*` files defensively where directories
are scanned (check rebuild-from-files glob patterns ignore them).

**Acceptance.** Concurrent-writer test produces two intact outcomes (last
write wins, no corruption); rebuild file globs ignore temp files.

### TD-22: Wrap `delete_chat_conversation` in a transaction

**Context.** `chat.ex` deletes all messages (`Repo.delete_all`) then the
conversation (`Repo.delete`) without a transaction — a failure in between
strands orphan message rows. The codebase uses `Repo.transaction`
conscientiously elsewhere; this is an outlier. (Check for siblings: any other
multi-statement write without a transaction found during work on this task
should be fixed in the same pass — e.g. audit `lib/bds/ai/catalog.ex`,
`lib/bds/scripts.ex`.)

**Files.**
- `lib/bds/ai/chat.ex` (`delete_chat_conversation/1` lines ~102–117)

**Approach.** `Repo.transaction(fn -> ... end)` or `Ecto.Multi`. Better:
add `ON DELETE CASCADE` via an Ecto migration on the
`chat_messages.conversation_id` FK and drop the manual `delete_all` (use
`mix ecto.gen.migration` per project rules).

**Acceptance.** Injected failure between the two deletes leaves both intact;
no orphaned messages possible.

### TD-23: Sweep blanket `rescue`/`catch` blocks for silent failure

**Context.** Several modules rescue *all* exceptions into `:ok`/fallbacks
(`shutdown.ex` defensibly — it must never block quit; but also
`overlay_components.ex` (11 rescues), `import_execution.ex`,
`import_analysis.ex`, `main_window.ex`, `Repo.ready?`). Blanket rescues hide
real bugs (typos become silent no-ops) and dialyzer can't see through them.

**Files.** Start with: `lib/bds/desktop/shell_live/overlay_components.ex`,
`lib/bds/import_execution.ex`, `lib/bds/import_analysis.ex`,
`lib/bds/desktop/main_window.ex`.

**Approach.** For each rescue: narrow to the specific exception(s) actually
expected, add a `Logger.warning` with context where swallowing is the right
call, and delete rescues that guard nothing. Shutdown.ex's rescues stay as-is
(documented intent: never block quit).

**Acceptance.** No bare `rescue _ ->` without either a narrow exception match
or a logged justification; suite green.

### TD-24: Fix stale `npm test` reference in AGENTS.md

**Context.** AGENTS.md "Fix All Test Failures" section says "Run the full
test suite (`npm test`)" — stale from the pre-Elixir rewrite. It's an
instruction file for agents; wrong commands actively mislead.

**Files.** `AGENTS.md`

**Approach.** Replace with `mix test` (and the `xvfb-run mix test` headless
note already present elsewhere in the file). While in there, scan for other
JS-era references (React components are mentioned in the i18n section —
verify whether that section should say LiveView/HEEx).

**Acceptance.** AGENTS.md commands all match the Elixir toolchain.

### TD-25: Generate the desktop endpoint secret at runtime ✅ DONE (2026-06-11, shipped with TD-01)

**Context.** The Phoenix endpoint `secret_key_base` (session/LiveView
signing) was a hardcoded repo string in all envs.

**Status: implemented as part of TD-01.** `BDS.Application.desktop_secret_key_base/0`
now generates `Base.encode64(:crypto.strong_rand_bytes(48))` per boot when no
explicit config is set; the static value was removed from `config/config.exs`.

---

## Explicit non-issues (decisions reviewed and endorsed)

Recorded so future reviews don't re-litigate them:

- **Shelling out to `git`** instead of libgit2 NIF bindings — correct;
  bindings are immature. (Timeout gap tracked as TD-10.)
- **SIGKILL shutdown** for the wx static-destructor segfault — legitimate,
  well-documented workaround. (Terminate-callback consequence tracked as TD-04.)
- **`BDS.BoundedAtoms`** allow-list atom conversion — good practice, keep.
- **Luerl with reduction/time caps** for user scripting — right tool, sound
  sandbox config.
- **SQLite FTS5 + bm25** for search, **HNSWLib** for ANN, **Liquex/Earmark**
  for rendering — all appropriate.
- **Integer-millisecond timestamps** (`Persistence.now_ms`) over
  `:utc_datetime_usec` — committed design choice; consistent; keep
  `parse_timestamp`'s seconds-vs-ms heuristic under test, don't migrate.
- **`elixir-desktop` dependency risk** (niche, lightly maintained) —
  acknowledged; mitigation is the existing thin `BDS.Desktop.*` boundary, not
  replacement.
- **No telemetry pipeline** — reasonable cut for a desktop app; revisit only
  if support/debugging demands it.
