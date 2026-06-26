# Elixir Antipatterns Audit (v2)

Incorporates reviewer corrections (v1 listed some already-moduledoced/specced modules as undocumented; mischaracterised `git.ex:724`; implied `shell_live.ex` is still monolithic when its event handlers are already delegated to `OverlayManager`, `SidebarEvents`, `TitlebarMenu` etc.; overstated the risk of `search.ex:744` whose atom is already bounded by `@stemmer_algorithms`; missed reusable anchors like `MapUtils`, `Slug`, `I18n`). `mix credo --strict` passes clean — everything below is a semantic antipattern lint cannot catch.

Static review of `lib/` (246 files, ~58k LOC).

---

## H1 — Stray `Logger.info` leaking raw user input

`lib/bds/desktop/shell_live/chat_editor.ex:93` logs `socket.assigns.input` at `info` level; `:98` is a sibling stray. These two lines violate AGENTS.md and leak raw user input to production logs. Everywhere else the codebase uses `Logger.debug` with a `swallowed` convention.

### Attack
1. Delete `chat_editor.ex:93` and `:98`.
2. `grep -rn "Logger\.info(" lib` and audit every other hit (only legitimate operational events should remain).
3. Optional: add a credo check banning `Logger.info(inspect(` in `LiveView` modules.

### Test strategy
No test changes — pure deletion.

---

## H2 — Hardcoded user-facing language-name map

`lib/bds/desktop/shell_live/overlay_components.ex:209-217`:

```elixir
defp language_names do
  %{"en" => "English", "de" => "Deutsch", "fr" => "Francais", "it" => "Italiano", "es" => "Espanol"}
end
```

Violates AGENTS.md ("No hardcoded user-facing text. No exceptions.") The repo already has the right central home: `BDS.I18n` (`lib/bds/i18n.ex:1`) already holds `@supported_languages`, flags, format locales, and language metadata.

### Chosen semantic: native autonyms
Language labels in the overlay are language *self-names* ("Deutsch", "Español") — they identify a language, they don't need to be translated into the UI locale. A German user seeing "Español" for Spanish is correct (it's the Spanish self-name), just as `@supported_languages` already lists flags per language without translating the flag.

Therefore: **centralise in `BDS.I18n`, no Gettext needed.** Do not introduce `dgettext("ui", "language.<code>")` for this — that would create a translation task with no real user benefit.

### Attack
1. Add `BDS.I18n.language_name/1` returning the native autonym for each supported code: `en → "English"`, `de → "Deutsch"`, `fr → "Français"`, `it → "Italiano"`, `es → "Español"`. Keep aligned with `@supported_languages`.
2. Replace `language_names/0` in `overlay_components.ex:209` with a `BDS.I18n` lookup (build the map from `I18n.supported_languages/0` and `I18n.language_name/1`).
3. Do NOT run `mix gettext.extract` for this — no new `msgid` entries.

### Test strategy
Add a test asserting `I18n.language_name/1` covers exactly `@supported_language_codes` and each value is non-empty.

---

## H3 — Shared-helper duplication with semantic drift

Already-existing canonical anchors (reuse these, don't invent new modules first):

- `BDS.MapUtils.blank_to_nil/1`  (`lib/bds/map_utils.ex:33-35`) — used in `media/file_ops.ex:10` via `defdelegate`. Currently only handles `nil` and `""`. **Note on naming**: `MapUtils` is the existing home for `blank_to_nil/1`, but new scalar predicates (`present?/1`, `blank?/1`, `truthy?/1`) do **not** belong in a module called "MapUtils" — they operate on scalar values, not maps. Add a new module `BDS.Values` (or `BDS.Booleans`) for those, and have `BDS.Values.blank_to_nil/1` `defdelegate` to `BDS.MapUtils.blank_to_nil/1` to keep the existing 20 callers untouched. The existing `blank_to_nil/1` stays in `MapUtils` to avoid churn.
- `BDS.Slug.slugify/1`  (`lib/bds/slug.ex:6`) — used in `posts.ex`, `templates.ex`, `posts/slugs.ex`. Canonical slugifier.
- `BDS.I18n`  (`lib/bds/i18n.ex`) — already centralizes supported-language metadata (see H2).

### Inventory

| Helper | defs | Sites | Disagreement | Canonical source |
|---|---|---|---|---|
| `truthy?/1` | 13 | `scripting/capabilities/util.ex:160`, `ai/catalog.ex:329`, `chat_editor.ex:584`, `chat_editor/tool_surfaces.ex:306`, `post_editor/post_metadata.ex:213`, `post_editor/draft_management.ex:230`, `settings_editor/{project,editor,managed_categories,ai}_settings.ex` | `1.0`? `"on"`? order of clauses? **Adding `"on"` to `ai/catalog.ex` is a silent widening — see attack step 1.** | **ADD** `BDS.Values.truthy?/1` (new module — scalar predicates don't belong in `MapUtils`) |
| `present?/1` | 8 | `ui/sidebar.ex:1128`, `posts/translation_validation.ex:495`, `posts/auto_translation.ex:447`, `import_editor/taxonomy_editing.ex:287`, `import_editor/analysis_state.ex:313`, `import_editor.ex:1455`, `chat_editor.ex:1034`, `panel_renderer.ex:303` | **whitespace trim?** — `translation_validation`, `auto_translation`, `chat_editor` trim; the other 5 do NOT | **ADD** `BDS.Values.present?/1` (non-trim canonical, matches current `blank_to_nil/1`) |
| `blank?/1` | 8 | `ui/dashboard.ex:197`, `post_editor/post_metadata.ex:218`, `import_editor.ex:1456`, `chat_editor/model_selection.ex:79`, `ai/runtime.ex:110`, `ai/chat_tools.ex:708`, `ai/chat.ex:938` | ditto whitespace | **ADD** `BDS.Values.blank?/1` (negation of `present?/1`) |
| `blank_to_nil/1` | 14 local + 20 direct `MapUtils.blank_to_nil/1` callers | see grep above | most agree: `nil`/`""` → `nil`; `git.ex:724` adds `"\n"`; `maintenance/diff_computation.ex:33-42` and `scripting/capabilities/util.ex:166-172` trim; the rest don't. **`MapUtils` version is non-trimming and load-bearing — do not mutate.** | **REUSE** `BDS.MapUtils.blank_to_nil/1` as-is; add `trim_or_nil/1` separately if needed |
| `pad2/1` | 4 | `scripting/capabilities/util.ex:163`, `post_editor/post_metadata.ex:207`, `overlay_components.ex:408`, `rendering/links_and_languages.ex:141` | identical bodies | **NEW** `BDS.Strings.pad2/1` |
| `slugify/1` | 2 custom | `rendering/filters.ex:74` (Liquex filter, leave), `overlay_components.ex:410` (delete; reuse `BDS.Slug.slugify/1`) | — | **REUSE** `BDS.Slug.slugify/1` |

### Required deliverable before any deletion
A table per helper of the form "site → semantic that site actually relies on → chosen canonical". Without it, deduping `present?/1` silently changes whitespace behaviour at the trim-using sites (and vice versa).

### ⚠ WARNING — `MapUtils.blank_to_nil/1` semantic change is a repo-wide migration, not a dedup

`BDS.MapUtils.blank_to_nil/1` (`map_utils.ex:33-35`) currently does **no trimming** — it maps `nil → nil`, `"" → nil`, anything-else → as-is. It has **20 direct callers** across `tags.ex`, `import_editor/*`, `ai/chat_tools.ex`, `ai/chat_tool_query_helpers.ex`, `wxr_parser.ex`, `import_analysis.ex`, and a `defdelegate` in `media/file_ops.ex:10`. Several of those callers already chain `|> String.trim() |> BDS.MapUtils.blank_to_nil()` (e.g. `taxonomy_editing.ex:153,232`), which proves the current non-trimming contract is load-bearing — callers compose trimming themselves.

Changing `map_utils.ex:33` to trim globally would **double-trim** at those sites and silently alter whitespace behaviour at every other caller. This is a migration, not a canonicalization.

### Attack
1. **Do not touch `BDS.MapUtils.blank_to_nil/1` semantics.** Leave its current contract (non-trimming) intact.
2. Create a new module `BDS.Values` for scalar predicates (do **not** add them to `MapUtils` — they're not map utilities). Have `BDS.Values.blank_to_nil/1` `defdelegate` to `BDS.MapUtils.blank_to_nil/1` to keep existing 20 callers untouched:
   - `BDS.Values.present?/1`  → `blank_to_nil(v) != nil` (non-trim semantic — matches the current `blank_to_nil/1` contract and the 5 non-trim `present?` sites).
   - `BDS.Values.blank?/1`    → `blank_to_nil(v) == nil` (negation).
   - `BDS.Values.truthy?/1`  → canonical accept set `true, "true", "on", 1, 1.0, "1"`.
   - Optional `BDS.Values.trim_or_nil/1` for the 3 sites that want trim-with-nil-empty — let those call sites compose `String.trim()` + `blank_to_nil/1` explicitly (as `taxonomy_editing.ex` already does), do not force a new helper on them.
3. **`truthy?/1` accept-set widening is a real semantic change at `ai/catalog.ex:329`.** Current local: `value in [true, "true", 1, "1"]`. Canonical adds `"on"` and `1.0`. The `catalog.ex:114-116` call sites feed `truthy?(BDS.MapUtils.attr(attrs, :supports_attachment))` etc. where `attrs` comes from external catalog config.
   - Verify that catalog config never produces `"on"` or `1.0` for those fields. If it can, EITHER keep `catalog.ex:329`'s local `defp` with its narrower accept set, OR prove via test that widening is safe (e.g. upstream already normalizes to `true`/`"true"`/`1`).
   - Do NOT blanket-alias `BDS.Values.truthy?/1` at `catalog.ex` without that verification. The "check callers" caveat is load-bearing.
3. **Migrate sites in two groups — don't blanket-delete.** The local `defp`'s split by semantic:
   - **Non-trim sites** (matches canonical `BDS.Values.present?/1`): `ui/sidebar.ex:1128`, `import_editor/taxonomy_editing.ex:287`, `import_editor/analysis_state.ex:313`, `import_editor.ex:1455`, `panel_renderer.ex:303` — delete local `defp`, `alias BDS.Values`. Same for `blank?/1` non-trim sites: `ui/dashboard.ex:197`, `import_editor.ex:1456`, `ai/runtime.ex:110`, `ai/chat.ex:938`.
   - **Trim sites — DO NOT migrate to `BDS.Values.present?/1` without a deliberate behavior change.** These rely on `String.trim` semantics:
     - `posts/auto_translation.ex:447` (`present?/1` trims)
     - `posts/translation_validation.ex:495` (`present?/1` trims)
     - `chat_editor.ex:1034` (`present?/1` trims)
     - `chat_editor/model_selection.ex:79` (`blank?/1` trims)
     - `ai/chat_tools.ex:708` (`blank?/1` trims with `to_string`)
     - `post_editor/post_metadata.ex:218` (`blank?/1` defers to local `blank_to_nil/1` that may trim — verify)
     For these sites either:
       (a) leave the local `defp` in place (safe default — no behavior change), or
       (b) migrate callers to `String.trim(value) |> BDS.Values.blank_to_nil(value) != nil` inline, with a test proving the trim behavior is preserved.
     Do NOT alias `BDS.Values.present?/1` at these sites — `present?(" ")` returns **true** under the canonical, **false** under the current local. That is a silent semantics change.
   - **`truthy?/1` sites** — apply step 2's catalog.ex check to all 13 sites before blanket-aliasing, since each may have its own narrower accept set (e.g. `ai/catalog.ex:329` omits `"on"`).
4. **Honest framing**: this is a *partial* dedup. After the migration, the canonical `BDS.Values.present?/1`/`blank?/1`/`truthy?/1` exists, but **several local `defp`s survive** at the trim sites and at sites whose accept-set differs from canonical. The goal is consolidation where safe, not full convergence — full convergence would require touching every behavior boundary. Don't oversell the payoff — this is medium-effort/high-risk dedup of one-line predicates.
5. Add `BDS.Strings.pad2/1` (or `BDS.Formatting.pad2/1`) — single 4-line implementation. Delete 4 local copies.
6. `overlay_components.ex:410` local `slugify/1` → replace with `BDS.Slug.slugify/1`.
7. Leave `git.ex:724`, `maintenance/diff_computation.ex:33`, `scripting/capabilities/util.ex:166` as-is for now — they're internal `defp`s whose callers expect their specific trim/newline behavior. File a follow-up to migrate them to `BDS.Values.trim_or_nil/1` if convergence is desired later.

### Test strategy
- New unit tests for canonical helpers covering: `nil`, `""`, `" "`, `"\n"`, `"x"`, `0`, `1`, `1.0`, `true`, `false`, `"true"`, `"on"`, `"1"`.
- Crucial: `present?(" ")` and `present?("\n")` return **true** with the non-trim canonical (matching the current `MapUtils.blank_to_nil/1` contract). A change here means every call site that expected `" "` to be blank needs migration — that is the migration mentioned above.
- After deleting a local `defp`, grep same-name to confirm no latent callers (some `defp` shadow `def` from a sibling module — careful with `scripting/capabilities/util.ex:160` which is `def`, not `defp`).
- `mix test` green. Test the post-field trim sites specifically (`posts/auto_translation.ex:447`, `posts/translation_validation.ex:495`) — they currently trim, and switching them to a non-trimming `present?/1` changes their semantics on whitespace strings.

---

## H4 — `try/rescue` for control flow and error swallowing

Most `rescue` clauses are legitimate. Categorised:

### Problem (rewrite to `case`/`with`)
`lib/bds/desktop/shell_live/overlay_components.ex`:
- `:71-77`, `:201-205`, `:257-261`, `:296-300`, `:328-338`, `:351-361`, `:390-400` — `{:ok, _} = Metadata.get_project_metadata(...)` followed by broad `rescue error ->`. The rescue catches a `MatchError` from a `{:error, _}` return — should be `case`/`with` over the `{:ok, _} | {:error, _}` shape.

### Over-defensive DB rescues (remove or narrow to `:error` log)
`lib/bds/desktop/shell_live/overlay_components.ex`:
- `:142`, `:157`, `:170`, `:190`, `:257` (the `Repo.all` ones) — wrap plain queries in rescue → return `[]`/`%{}`. A dropped table or lock is silently swallowed. Either drop the rescue and let it propagate, or log at `:error` (not `:warning`) and return `{:error, _}` up the call chain.

### Caller-expected fallback contracts (per function)
An agent removing a rescue needs to know what the caller expects on failure. These are the **current observed** fallbacks — preserve them unless the caller is also rewritten:

| Function | Line | Current fallback | Replace rescue with |
|---|---|---|---|
| `project_metadata/1` | `:71` | `%{main_language: "en", blog_languages: []}` | `case`/`with` returning the same map on `{:error, _}` |
| `source_language/2` (post) | `:201` | `metadata.main_language \|\| "en"` | `case` returning same on error |
| `source_language/2` (media) | `:201` | `metadata.main_language \|\| "en"` | same |
| `ai_fields/2` (post) | `:257` | `[]` | `case` returning `[]` on error |
| `ai_fields/2` (media) | `:296` | `[]` | `case` returning `[]` on error |
| `delete_details/2` (media) | `:328` | `%{title: dgettext("ui","Delete Media"), …, reference_list: []}` | `case` returning same on error |
| `delete_details/2` (tags) | `:351` | `%{title: dgettext("ui","Delete Tag"), …}` | `case` returning same on error |
| `merge_details/2` | `:390` | `%{target: "tag", count: 1, …}` | `case` returning same on error |

The 5 `Repo.all` rescues (`:142`, `:157`, `:170`, `:190`, `:257`) currently fall back to `[]` or `%{}`. If the live template already treats empty list as "no data" gracefully, the fallback is fine — but the *failure* should not be silent. Recommended: log at `:error` before returning the fallback so a DB/schema issue shows up in logs.

### Allow-list (leave alone)
- `preview.ex:246` — `rescue Ecto.NoResultsError -> {:error, :not_found}`. **Genuinely narrow**: single named exception type, expected control-flow case (post not found). Legitimate.
- `shutdown.ex` (10×), `main_window.ex`, `automation.ex`, `deep_link.ex`, `shell_commands.ex:630,814` — fire-and-forget teardown; `Logger.debug("swallowed ...")` then `:ok`. These explicitly tolerate `:exit`/`:noproc` during process shutdown and re-running them is racy. Legitimate.

### NOT on allow-list (re-examine)
- `embeddings/index.ex:348` — `rescue exception -> Logger.debug("swallowed embeddings index persist error..."); :ok`. **Broad rescue** wrapping `HNSWLib.Index.save_index/2` + `File.mkdir_p!`. A persist failure is silently swallowed and `:ok` returned — caller believes the index was saved. Operationally tolerable only because the next reindex will retry; should at minimum log at `:error` and ideally surface `{:error, _}`. **Re-examine**: not a blanket "leave alone".
- `embeddings/index.ex:393` — similar broad rescue around index load. Same caveat.
- `embeddings/backends/neural.ex:110` — `rescue exception -> {:reply, {:error, Exception.message(exception)}, state}`. **Broad rescue** around `Nx.Serving.run`. Unlike the silent-default cases above, this one *does* surface `{:error, _}` to the caller (good) — it's not a silent swallow. The reason it's still on the rework list is that the broad `rescue exception ->` catches programmer bugs (`FunctionClauseError`, `MatchError`) and repackages them as `{:error, "…"}` alongside genuine Nx runtime errors, hiding the distinction. **Re-examine**: restrict to expected Nx/serving exception types so programmer bugs surface unmodified.

To find: `grep -rn "rescue" lib`.

### Attack
1. For each of the 7 `overlay_components.ex` `{:ok, _} = ` rescues, rewrite as:
   ```elixir
   case Metadata.get_project_metadata(project_id) do
     {:ok, metadata} -> metadata
     {:error, _reason} -> %{main_language: "en", blog_languages: []}
   end
   ```
   Drop the rescue.
2. For the 5 `Repo.all` rescues (`overlay_components.ex:142,157,170,190,257`): **preserve the documented `[]`/`%{}` fallbacks** — the caller templates consume them directly. Letting `Repo.all` propagate is a behavior change and NOT the default repair. The correct minimal repair is:
   - narrow the rescue to a single named exception type if possible (`Ecto.QueryError`, `DBConnection.ConnectionError`), AND
   - upgrade the log from `Logger.warning` to `Logger.error` so silent DB/schema failures are visible, AND
   - keep the existing fallback return (`[]` or `%{}`) per the table above.
   Only if a caller is also being rewritten to accept `{:error, _}` (and has a test for it) should the rescue be dropped in favor of propagation. Introducing a repo-wide `BDS.RepoHelpers.safe_all/2` is **one option, not the prescribed repair** — the audit does not establish enough callers want this wrapping to justify a new abstraction; keep any wrapping local unless a second use site appears.
3. Keep `log_overlay_warning/2` (or move into a shared `BDS.Logging` module — see H3 territory).

### Test strategy
- Each rewritten function needs a test for the `{:error, _}` branch — currently impossible because of `rescue`. Use mox/mocks against `Metadata` and `Repo`.
- For over-defensive DB rescues, test the legitimate DB error path returns `{:error, _}` to the caller (or surfaces it).

### Rescue allow-list reference (tightened)
- Single **named exception type** (`Ecto.NoResultsError`, `File.Error`, `ArgumentError`) — OK.
- Fire-and-forget teardown in shutdown/process-kill paths with `Logger.debug("swallowed ...")` + `:ok` — OK.
- Broad `rescue exception ->` (or `rescue error ->`) returning a **silent default** (e.g. `:ok`, `[]`, `%{}`) — **NOT OK**, even if the operation is "background". At minimum log at `:error` so programmer bugs (`MatchError`, `FunctionClauseError`) are visible. `index.ex:348,393` falls in this category.
- Broad `rescue exception ->` that **does surface `{:error, _}`** (e.g. `neural.ex:110`) — **borderline**. The failure isn't silent, but a programmer bug is indistinguishable from a genuine runtime error after repackaging. Restrict to expected exception types rather than blanket-leaving.

---

## M1 — God modules: complete the decomposition that's already underway

Decomposition has already started. Acknowledge what exists, finish the rest.

Already extracted (don't redo):
- `lib/bds/desktop/shell_live/overlay_manager.ex` — `shell_live.ex:361-410` already delegates all 15 `overlay_*` events here.
- `lib/bds/desktop/shell_live/sidebar_events.ex` — sidebar filter events.
- `lib/bds/desktop/shell_live/titlebar_menu.ex` — titlebar menu state/logic.
- `lib/bds/desktop/shell_live/bridges.ex`, `git_handler.ex`, `chat_editor.ex`, `import_editor.ex`, `media_editor.ex`, `post_editor.ex`, `misc_editor.ex`, `settings_editor.ex`, `script_editor.ex`, `template_editor.ex`, `tags_editor.ex`, `menu_editor.ex` — body already lives in these.

Still routed through `shell_live.ex:183-547` (~55 `handle_event` clauses). The remaining forwarders cluster cleanly:

- **Project cluster** (`shell_live.ex:449-481`): `toggle_project_menu`, `close_project_menu`, `select_project`, `create_project`, `import_project` — extract to `BDS.Desktop.ShellLive.ProjectEvents`.
- **Language cluster** (`shell_live.ex:514-518`): `change_ui_language`, `sync_ui_language` — extract to `BDS.Desktop.ShellLive.LocaleEvents` (and tie to `UILocale` — see M2).
- **Native menu cluster** (`shell_live.ex:527-547`): `native_menu_action`, `titlebar_menu_keydown`, `toggle_titlebar_menu`, `hover_titlebar_menu`, `close_titlebar_menu`, `titlebar_menu_action` — extract to `BDS.Desktop.ShellLive.NativeMenuEvents` (already co-located with `titlebar_menu.ex`).
- **Tab/workspace cluster** (`:196-302`): view/panel/tab/sidebar-item — extract to `BDS.Desktop.ShellLive.WorkspaceEvents`.

What stays in `shell_live.ex`: `mount`, `handle_info`, `terminate`, and a small handful of top-level routing events.

Out-of-scope decompositions (large but not urgent — touch when working nearby):
- `lib/bds/scripting/api_docs.ex` (1554 LOC) — split `Renderer` / `Generator` / `DataStructures` when scripting docs change next.
- `lib/bds/ui/sidebar.ex` (1129) — split `Sidebar.Filters` from `Sidebar.View` opportunistically.
- `lib/bds/ai/chat.ex` (939) — orchestration; leave unless actively edited.

### Attack
1. Pick one cluster. Create the module, move the matching `handle_event` clauses verbatim, leave a single delegating `handle_event` in `shell_live.ex` per event (same pattern as `:361-410`).
2. Verify with the existing LiveView test suite after each cluster.

### Test strategy
Existing LiveView tests (`live/2`) exercise events by name — they should pass unchanged after delegation.

---

## M2 — Process dictionary as contained global

`lib/bds/desktop/ui_locale.ex` is the documented sole owner of `Process.put(:bds_ui_locale, _)`. The module explicitly comments that direct use elsewhere is forbidden. This is **not a present defect** — it's a caution for future work.

### Attack
1. No retrofit needed.
2. For NEW callers needing the locale, prefer passing it explicitly via assigns or a `%Locale{}` struct rather than expanding `Process.put` callers.
3. Consider a dialyzer / credo custom check rejecting new `Process.put(:bds_ui_locale, _)` outside `UiLocale`.

Priority: **Informational**. No action required unless new callers appear.

---

## M3 — `Enum.at` brittle index use

### Real problems (rewrite)
- `lib/bds/import_analysis.ex:428-429`:
  ```elixir
  key = Enum.at(captures, 1)
  value = Enum.at(captures, 2) || Enum.at(captures, 3) || Enum.at(captures, 4) || ""
  ```
  Rewrite with `Regex.named_captures/2` or pattern matching on the captured groups.
- `lib/bds/rendering/filters.ex:241-253` — `match |> Enum.at(1)` repeated 4× with identical shape. Hoist into a helper and pattern match.

### Style only (drop from report)
- `titlebar_menu.ex` `== nil` vs `is_nil/1` inconsistency — cosmetic.

To find: `grep -rn "Enum\.at\|Enum\.find_index\|Enum\.find_value" lib`.

### Attack
1. `import_analysis.ex:428-429` → switch regex to named groups, return map, pattern-match defaults.
2. `rendering/filters.ex:241-253` → introduce `slug_from_match/1` private helper, reuse across 4 call sites.

### Test strategy
Tests for: empty captures list, regex without the expected group, full match. Existing tests should still pass.

---

## M4 — Documentation debt

Many modules still carry `@moduledoc false`, including public-API modules. The reviewer correctly points out:
- `templates.ex:1` already has a real `@moduledoc """..."""`.
- `tasks.ex:13` is heavily `@type`/`@spec`-ed.
- `tags.ex:18` and `posts.ex:64` have broad public `@spec` coverage.

So the v1 claim "no specs" was wrong for those four. The genuine gap:

- **Missing moduledoc on API modules**: `posts.ex:1`, `media.ex:1`, `preview.ex:1`, `ai/chat.ex:1`, `embeddings.ex:1`, `generation.ex:1`, `git.ex:1`, `tags.ex:1`. Verify each individually before flipping.
- **Missing `@spec` on a few remaining public `def`s** in `preview.ex:1` — spot-apply, don't bulk-generate. (Note: `metadata.ex:1` is **fully specced** — 9/9 public defs have `@spec`. Removed from the gap list.)
- **CI gap**: `mix.exs` does not currently include `ex_doc`. "Run `mix docs`" is therefore **not** a usable verification path until `ex_doc` is wired.

### Attack
1. **Prerequisite**: add `:ex_doc` to `mix.exs` `deps` (dev-only). Configure `mix docs --warnings-as-errors` in CI.
2. Audit `grep -rn "@moduledoc false" lib`. For each module that is `alias`ed from outside its own subtree, replace `@moduledoc false` with a real `@moduledoc """..."""` describing intent and contract. Keep `false` for `*HTML`, `*Components`, `Web.Live.*` view plumbing, and similar internal modules.
3. Add missing `@spec` to the public-API functions flagged by `mix docs --warnings-as-errors`.
4. Do NOT bulk-add specs to private helpers — knock-on churn.

Priority: **Medium**, after `ex_doc` is wired. Documentation debt, not a high-priority defect.

### Test strategy
CI gate via `mix docs --warnings-as-errors` once `ex_doc` is added.

---

## L1 — `cond do ... true ->` repetition

Mostly cosmetic. Example in `chat_editor.ex:945-949` re-fetches `Map.get(surface, :title)` thrice. Opportunistic cleanup, not audit-worthy. Touch when working nearby.

Priority: **Low**. No dedicated task.

## L2 — `apply/3` with a parsed atom (informational only)

`lib/bds/search.ex:743-744` already bounds the atom via `Map.fetch(@stemmer_algorithms, normalize_language(language))` before `apply(Stemex, algorithm, [token])`. **Not a dynamic-dispatch hazard** in current code. Optional improvement: add `@allowed_stemmer_atoms Map.values(@stemmer_algorithms)` and a guard for defense-in-depth when the list changes.

Priority: **Low**. No dedicated task.

---

## Suggested fix priority (re-ranked)

| # | Item | Effort | Risk |
|---|---|---|---|
| 1 | H1 delete stray `Logger.info` in `chat_editor.ex:93,98` | tiny | none |
| 2 | H2 externalise `language_names` into `BDS.I18n` as native autonyms (no gettext) | small | low |
| 3 | H4 rewrite `{:ok,_}=…rescue` in `overlay_components.ex`; narrow DB rescues (preserve fallbacks) | medium | medium |
| 4 | M1 extract remaining `shell_live.ex` event clusters (project / locale / native-menu / workspace) | medium | low (delegation preserves behaviour) |
| 5 | M3 `Enum.at` brittle cases in `import_analysis.ex:428` and `rendering/filters.ex:241` | small | low |
| 6 | M4 wire `ex_doc`; flip public-API `@moduledoc false`; close `@spec` gaps | medium | none |
| 7 | H3 consolidate helpers into new `BDS.Values` (with semantic inventory) — **last because: medium effort, high risk for one-liner predicates, partial dedup payoff** | medium | high (trim vs non-trim boundary + truthy accept-set widening at `catalog.ex`) |

Schedule L1/L2 opportunistically when touching those files.

---

## Required verification after each task

Per AGENTS.md, a task is not done until all five are green:

```
mix test                      # or: xvfb-run mix test   on headless Linux
mix compile --warnings-as-errors
mix credo --strict
mix deps.audit
mix dialyzer
```