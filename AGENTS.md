# Agents Instructions for Elixir rewrite of the Blogging Desktop Server (bDS2)

This document provides context and best practices for GitHub Copilot when working on this blogging application.

## Plan Mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- At the end of each plan, give me a list of unresolved questions to answer, if any.

## Commits

- commit messages are short - one sentence. do not write long articles.
- pull requests are more verbose and especially give reasoning for changes

## Important facts

- published posts don't have body in the database, the body content is only in the file
- functionality you implement have to be tied to UI
- UI you implement has to be tied to functionality
- you must use ecto to generate migrations and snapshots
- on MacOS we use native menus and you have to hook them into the intercept for new menu items
- there are two areas of localization, you sometimes need both (menus for example)
- localization is done with elixier gettext and you need mix gettext.extract to update translation files
- all automatic AI activities must be gated by airplane (offline) mode of the app and either use the local model or inform the user via toast
- metadata needs to be flushed to the filesystem and needs to be included in metadata diff tool and in rebuild from filesystem. All three aspects have to be in sync with each other.
- if you add new metadata, add them to publishing, metadata-diff and rebuild-from-database
- HEREDOCs don't work most of the time. Don't use them. Use editor tools to create proper scripots
- we have an allium spec in the specs/ folder. you must weed the specs against built code to make sure you follow the spec.
- when changing the spec, validate the spec with the available command line tool.
- you MUST run tests with command line tools at least once to capture compile errors in tests, do not use the integrated testing of vscode, as that blocks on compile errors
- you MUST run build, test, credo, deps.audit and check dialyzer messages and you MUST treet warnings as errors and fix them. we want clean builds, clean tests, clean credo, clean dependency audits and clean dialyzer results
- on a headless Linux machine, you have to run tests with this command (if mix test complains about DISPLAX): xvfb-run mix test

---

## ⚠️ MANDATORY: Test-First Development

**STOP!** Before writing ANY implementation code, you MUST:

1. **Write a failing test first** that describes the expected behavior
2. **Run the test** to confirm it fails (Red)
3. **Write minimal code** to make the test pass (Green)
4. **Refactor** while keeping tests green

> **No code without tests. No exceptions.**
>
> Tests must import and exercise the REAL implementation classes, not inline helper functions.
> Mock only external dependencies (database, filesystem), never the class under test.

---

## ⚠️ MANDATORY: Fix All Test Failures

**You MUST investigate and fix ALL test failures before completing any task.**

- Never leave tests failing, even if they appear unrelated to your changes
- If a test failure is pre-existing, fix it as part of your current work
- **Always write the full test run to a log file first, then grep that file for failures.** Never run `mix test` in the terminal and try to grep live output — the output is interleaved, truncated, and nearly impossible to parse. Pattern:
  ```
  mix test 2>&1 > /tmp/test_run.log
  grep -E "FAILED|^[ ]*1\)" /tmp/test_run.log
  grep -A 15 "^[ ]*1\)" /tmp/test_run.log   # details for the first failure
  ```
  Work from the log file, not from repeated terminal runs.

> **Zero failing tests. No exceptions.**
- Run the full test suite (`mix test`) before considering any task complete
- If you cannot fix a test, explain why and propose a solution

> **Zero failing tests. No exceptions.**

---

## ⚠️ MANDATORY: Remove Unused Code

**Never keep unused code around. Always delete it completely.**

- When a feature is removed, delete ALL related code (implementation, tests, types, configs)
- Do NOT comment out code "for later" - use version control history
- Do NOT skip tests for removed functionality - delete them
- Do NOT leave dead code paths, unused imports, or orphaned functions
- When refactoring, actively look for and remove any code that becomes unused

> **Delete unused code immediately. No exceptions.**

---

## ⚠️ MANDATORY: Build Verification After Code Changes

**You MUST run the full build after making code changes.**

- Run the build after any code modifications
- Fix ALL build errors before considering the task complete
- Build errors indicate issues
- The build must complete successfully before the task is complete

> **Successful build required. No exceptions.**

---

## ⚠️ MANDATORY: No External JS/CSS in Preview or Generated HTML

**Do not reference external JavaScript or CSS libraries (CDNs/remote URLs) from the preview server output or generated HTML.**

- Preview HTML must reference only local/package-bundled assets
- Generated HTML must not include CDN-hosted JS/CSS libraries
- If a library is needed (e.g., Pico CSS, Lightbox), include it as a local dependency and serve/reference it locally
- Avoid introducing any new `<script src="https://...">` or `<link href="https://...">` for library assets in preview/generated output

> **Preview and generated HTML must be self-contained with local assets. No exceptions.**

---

## ⚠️ MANDATORY: macOS Bundle Must Be Fully Standalone

**The built `BDS2.app` MUST run on a Mac without Homebrew.**

- No Mach-O inside the `.app` may reference a Homebrew/local path (`/opt/homebrew`, `/usr/local`)
- Every external dylib reachable from the release's NIFs must be copied into `Contents/Frameworks` and rewritten to `@loader_path`-relative install names (`BDS.MacBundle.Dylibs`)
- The same physical dylib referenced under multiple names must be deduped (one real file + symlinks) so dyld loads a single image — duplicate images cause duplicate Objective-C class / wx event-table registrations
- `BDS.MacBundle.verify_standalone/1` runs after relocation and fails the build if any external reference remains — do not weaken or bypass this gate

> **The bundle must be self-contained. No outside references. No exceptions.**

---

## ⚠️ MANDATORY: macOS Bundle Build Order and Blogmark Verification

**`mix release` copies `priv/static` as-is — it never rebuilds assets.** Always build in this order, or the bundle ships stale JS while the server code is current (this silently broke blogmark deep links in July 2026: the server waited for the client's `shell_ready` event that the stale `app.js` never sent, so every deep link queued forever with no error, no toast, no log):

```
mix assets.deploy
MIX_ENV=prod mix release bds --overwrite
mix bds.bundle.macos
```

**After building a bundle, verify blogmark deep links end-to-end with:**

```
scripts/verify_blogmark_macos.sh [path/to/BDS2.app]   # defaults to dist/macos/BDS2.app
```

The script launches the bundle via LaunchServices with an isolated database (`launchctl setenv BDS_DATABASE_PATH ...`), fires `bds2://new-post` links with `open -a` exactly like a browser bookmarklet, and asserts draft posts appear in the database — both for cold start (link launches the app, queued until the shell attaches) and for an already-running app. It refuses to run while any BDS2 instance is up; quit the app first.

Things learned the hard way, encoded in the script — do not "simplify" them away:

- Deep links only reach an app **launched through LaunchServices** (`open -a`). A process started by exec'ing `Contents/MacOS/bds2` from a shell never receives Apple Events, so deep links vanish without a trace. For the same reason `open` does not inherit the shell environment — inject env vars with `launchctl setenv` (and unset them afterwards).
- To introspect a running bundle, launch it with `RELEASE_DISTRIBUTION=name` and `RELEASE_NODE=bds@127.0.0.1` set (via `launchctl setenv`), then use `.../Contents/Resources/rel/bin/bds rpc '<elixir>'` with the same env. The default `-sname` node is unreachable when the hostname resolves to LAN addresses.
- The wx → `Desktop.Env` → `BDS.Desktop.DeepLink` → shell pipeline downstream of the OS can be exercised without LaunchServices via `send(Process.whereis(BDS.Desktop.DeepLink), {:open_url, ~c"bds2://new-post?..."})` over rpc.

> **Assets before release. Verify blogmarks after bundling. No exceptions.**

---

## ⚠️ MANDATORY: Proper I18N for UI and Rendering Text

**All user-facing text MUST follow proper i18n patterns.**

- Do not hardcode UI strings directly in LiveView/HEEx components, menu templates, dialogs, or toasts
- Store UI copy in language resources and resolve text through i18n helpers/hooks
- UI language MUST come from the operating system locale
- Rendering/preview/generated-content language MUST come from project preferences (`mainLanguage`), not UI locale
- Keep i18n usage consistent in both renderer UI and render/preview output
- For supported locales, translations MUST come from that locale file only; do not copy English terms into supported locale files as fallback
- English fallback is allowed only when the requested locale is unsupported by available locale files
- The project `mainLanguage` selector must expose exactly all supported render languages and no unsupported extras
- When adding new `msgid` entries, you MUST provide translations for ALL supported locales (de, fr, it, es) — empty `msgstr` values are not acceptable

> **No hardcoded user-facing text. No exceptions.**

---

## ⚠️ MANDATORY: Keep API Bindings and API Docs in Sync

**Whenever any app API is added, removed, or changed, you MUST update the script API bridge and API documentation in the same change set.**

- Update the API contract/bindings used by embedded scripts
- Regenerate and commit `API.md`
- Ensure every API entry documents:
  - Parameter names, types, and required/optional status
  - Return type/response specification
  - At least one sample script call
- Maintain a shared **Data Structures** section in `API.md` for canonical objects (for example `PostData`, `MediaData`) so users can see expected attributes in one place
- Keep docs sync tests passing (documentation and generator output must match)

> **No API contract drift between app APIs, script bindings, and API.md. No exceptions.**

