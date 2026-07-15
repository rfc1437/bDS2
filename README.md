# bDS2

bDS2 is the Elixir rewrite of bDS, the offline-first desktop blogging workspace. It is no longer just a rewrite scaffold: the repository now contains the main desktop runtime, Ecto persistence, filesystem-backed content workflows, rendering and publishing pipelines, Lua scripting, AI and MCP integration, and a Phoenix LiveView shell embedded in a native desktop window.

The Allium specs in [specs/](/Users/gb/Projects/bDS2/specs) remain the behavioral contract for the rewrite. For end-user operation, see [DOCUMENTATION.md](/Users/gb/Projects/bDS2/DOCUMENTATION.md). For the scripting surface, see [API.md](/Users/gb/Projects/bDS2/API.md).

## Current Status

The major architectural rework is in place.

- The desktop UI is served by Phoenix LiveView inside the desktop shell rather than by a separate handwritten frontend runtime.
- Assets use Phoenix-default Tailwind and esbuild tooling from [assets/](/Users/gb/Projects/bDS2/assets) into [priv/static/](/Users/gb/Projects/bDS2/priv/static).
- Core editorial flows are implemented in the main application: posts, media, tags, templates, scripts, imports, preview, generation, publishing, maintenance, AI, and MCP.
- Localization is now a first-class architectural concern rather than an afterthought: UI chrome and rendered site output have separate locale flows, and post/media translation workflows are built into the domain model.
- The app boots in three modes: the desktop app, a headless server (SSH-served terminal UI + tunneled GUI), and a local TUI — see [Headless Server Mode And Terminal UI](#headless-server-mode-and-terminal-ui).

The rewrite still aims to preserve the product behavior of bDS while replacing the technical stack. The contract is product behavior, not the old implementation language or framework choices.

## Architecture Overview

### Runtime

[BDS.Application](/Users/gb/Projects/bDS2/lib/bds/application.ex) is the supervision root. It starts the Phoenix endpoint, database, preview and publishing workers, task supervisors, scripting jobs, and the desktop server/window adapters.

At a high level, the stack is:

- Native windowing through the `:desktop` integration.
- Phoenix endpoint and LiveView shell for the actual app UI.
- Ecto + SQLite for indexed state, editor state, and app data.
- Filesystem-backed project data for published content, media, sidecars, scripts, templates, generated output, and rebuild workflows.

### Desktop Shell

The desktop workbench lives under [lib/bds/desktop/](/Users/gb/Projects/bDS2/lib/bds/desktop). The main screen is [BDS.Desktop.ShellLive](/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live.ex), with feature-specific editors and sidebar logic under [lib/bds/desktop/shell_live/](/Users/gb/Projects/bDS2/lib/bds/desktop/shell_live).

If you are tracing UI behavior, start there first:

- LiveView event routing, workbench state, overlays, and menu handling live in the desktop shell modules.
- HEEx templates under the same tree now own most common layout and state styling.
- Monaco is bundled as an ESM bundle via esbuild into `priv/static/assets/monaco.js` and `monaco.css` (source entry at `assets/js/monaco_entry.js`).

### Domain Modules

Most application behavior lives under [lib/bds/](/Users/gb/Projects/bDS2/lib/bds):

- posts, media, tags, templates, scripts, and project settings
- metadata, frontmatter, sidecars, rebuild, and maintenance
- rendering, generation, preview, and publishing
- AI runtimes, chat tooling, embeddings, and MCP
- scripting capabilities and generated API docs

The repo has been pushed toward smaller feature-focused modules rather than one large mixed runtime. For new work, prefer finding the owning feature module instead of adding more behavior to broad catch-all files.

### Storage Model

The database is important, but it is not the whole source of truth.

- Ecto models hold app state, indexes, editor state, and workflow data.
- The filesystem holds published content artifacts and sidecar metadata that must stay stable and reviewable.
- Rebuild and metadata-diff flows exist because database state and filesystem state are expected to stay in sync.

When you change persisted behavior, think in both directions: database writes and filesystem writes/readback.

## Localization And i18n

Localization now has two separate layers, and confusing them causes bugs.

### 1. UI Localization

UI chrome, menus, dashboard text, editor labels, and toasts use Gettext through [BDS.Gettext](/Users/gb/Projects/bDS2/lib/bds/gettext.ex) and the `ui` domain. Locale normalization lives in [BDS.I18n](/Users/gb/Projects/bDS2/lib/bds/i18n.ex), and the desktop shell binds the active UI locale through [BDS.Desktop.UILocale](/Users/gb/Projects/bDS2/lib/bds/desktop/ui_locale.ex).

In practice, this is the language of the app itself.

### 2. Render Localization

Rendered site output uses a separate locale flow. Archive labels, pagination text, template-facing render strings, and generated site language handling use the `render` Gettext domain and the project's `main_language` and `blog_languages` settings.

In practice, this is the language of the blog output, not necessarily the UI.

### 3. Content Translation

Posts and media have translation-aware workflows. Post translations and media metadata translations are modeled explicitly, and generation/preview/publishing use the project's configured languages when building output.

Relevant translation resources live under:

- [priv/gettext/](/Users/gb/Projects/bDS2/priv/gettext) for Gettext catalogs
- [priv/i18n/](/Users/gb/Projects/bDS2/priv/i18n) for additional locale data used by the app

If you touch i18n-sensitive behavior, check whether the change belongs to UI locale, render locale, or content translation. They are related, but they are not interchangeable.

## Frontend And Assets

Frontend source now follows the Phoenix asset layout:

- [assets/css/](/Users/gb/Projects/bDS2/assets/css) for Tailwind-based CSS modules
- [assets/js/](/Users/gb/Projects/bDS2/assets/js) for LiveView hooks, bridges, Monaco integration, and UI helpers
- [priv/static/assets/](/Users/gb/Projects/bDS2/priv/static/assets) for generated outputs

The rule of thumb is simple:

- common layout, spacing, state, and typography belong in HEEx and small shared UI primitives
- authored CSS stays for tokens and desktop-specific selectors
- JavaScript stays focused on LiveView hooks, editor integration, drag/drop, and browser APIs

## Repository Map

- [mix.exs](/Users/gb/Projects/bDS2/mix.exs): Mix project definition, aliases, releases, and dependencies
- [config/](/Users/gb/Projects/bDS2/config): runtime, dev, test, and asset configuration
- [lib/bds/](/Users/gb/Projects/bDS2/lib/bds): core application modules
- [lib/bds/desktop/](/Users/gb/Projects/bDS2/lib/bds/desktop): desktop endpoint, shell, menus, controllers, and window integration
- [assets/](/Users/gb/Projects/bDS2/assets): Tailwind and esbuild source
- [priv/repo/](/Users/gb/Projects/bDS2/priv/repo): Ecto migrations and snapshots
- [priv/gettext/](/Users/gb/Projects/bDS2/priv/gettext): UI and render translation catalogs
- [specs/](/Users/gb/Projects/bDS2/specs): Allium behavior specs
- [DOCUMENTATION.md](/Users/gb/Projects/bDS2/DOCUMENTATION.md): end-user guide
- [API.md](/Users/gb/Projects/bDS2/API.md): generated scripting API reference

## macOS Development Setup

If you are setting up a new macOS machine, install the toolchain first.

### 1. Install Xcode Command Line Tools

```bash
xcode-select --install
```

### 2. Install Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 3. Install Erlang, Elixir, and SQLite

```bash
brew update
brew install erlang elixir sqlite
```

### 4. Fetch Dependencies And Set Up The App

```bash
cd /Users/gb/Projects/bDS2
mix setup
mix assets.setup
```

## Development Workflow

Useful commands:

```bash
mix compile --warnings-as-errors
mix test
mix dialyzer
mix assets.build
```

## Headless Server Mode And Terminal UI

Since issue #26 the app has three boot modes, selected with the `BDS_MODE`
environment variable (any release or dev boot; default is the desktop app):

- `desktop` — the native desktop app, unchanged.
- `server` — headless: no window, loopback-only HTTP endpoint, CLI sync
  watcher, and an SSH daemon serving the terminal UI. Works on macOS,
  Windows, and Linux (no display needed).
- `tui` — the headless server plus a TUI attached to the launching terminal.

### Build and run a headless server

```bash
MIX_ENV=prod mix release bds --overwrite
BDS_MODE=server _build/prod/rel/bds/bin/bds start
```

The SSH daemon listens on port `2222` (`BDS_SSH_PORT` or
`config :bds, :server, ssh_port:` to change). Authentication is public-key
only: on first boot the server generates a host key and an empty
`authorized_keys` (mode 600) in `ssh/` next to the database (default
`~/Library/Application Support/BDS2/ssh/`, or under `BDS_DATABASE_PATH`).
Add your public key there, then connect from any terminal:

```bash
ssh -p 2222 <server-host>          # opens the TUI
```

Each SSH connection gets its own TUI session on the server; only terminal
cells cross the wire. All clients stay synchronized through the domain
event bus (`BDS.Events`) — a post created by a pipeline or another client
appears in every open shell.

### TUI keys

`↑/↓` or `j/k` navigate · `enter` open · `n` new post · `1-5` switch view
(posts/media/templates/scripts/tags) · `r` refresh · in the editor:
`ctrl+s` save, `ctrl+p` publish, `ctrl+e` word-wrapped preview,
`ctrl+t` title, `ctrl+l` language, `ctrl+g` AI suggestions
(airplane-mode gated), `esc` back · `ctrl+q` quit.
Images preview inline via the terminal image protocol. The UI language is
the server-side setting shared by every client.

### Remote GUI

The HTTP endpoint stays bound to `127.0.0.1` and is never exposed; GUI
clients tunnel through the same SSH daemon and keys:

```bash
ssh -p 2222 -L 4010:127.0.0.1:4010 -N <server-host> &
open http://127.0.0.1:4010
```

Or use the desktop app directly: **File → Connect to Server…** takes
`user@host[:port]`, connects with the client key from the same local
`ssh/` directory (public-key auth, trust-on-first-use `known_hosts`),
tunnels to the server, and points the window at it. **File → Disconnect
from Server** returns to the local workspace.

## Monaco Editor

Monaco is bundled via esbuild using its ESM entry point (`monaco-editor/esm/vs/editor/editor.main.js`). The
main bundle is built as part of `mix assets.build` and lives at `priv/static/assets/monaco.js` and
`monaco.css`; ESM worker bundles live under `priv/static/assets/monaco/`.

```bash
mix monaco.version    # show current monaco-editor version
mix monaco.update 0.55.1  # update to a specific version and rebuild the bundle
```

The update task runs `npm install monaco-editor@<version>`, cleans the old bundle, and rebuilds via esbuild.
See https://www.npmjs.com/package/monaco-editor for available versions.

Notes for developers:

- Specs in [specs/](/Users/gb/Projects/bDS2/specs) define the intended product behavior.
- [DOCUMENTATION.md](/Users/gb/Projects/bDS2/DOCUMENTATION.md) is for end users, not implementation details.
- [API.md](/Users/gb/Projects/bDS2/API.md) is generated from the live scripting capability map and should stay in sync with runtime changes.
- When changing persistence or localization behavior, check both the database side and the filesystem/render side before assuming the change is complete.

## Packaging The macOS App

`mix bds.bundle.macos` produces a self-contained, ad-hoc-signed `BDS2.app`. It
bundles the `:bds` release (ERTS included) plus the wxWidgets dylibs relocated
via `@loader_path`, so it runs on a clean Mac with nothing installed. The bundle
registers the `bds2://` URL scheme (for blogmark deep links) and ships the red-pen
`AppIcon`. Output: `dist/macos/BDS2.app`. (arm64 / Apple Silicon only.)

### 1. Build the release, then the bundle

```bash
MIX_ENV=prod mix release bds --overwrite
mix bds.bundle.macos --app-release _build/prod/rel/bds
```

The icon `.icns` is generated on first run from
[priv/desktop/macos/icon-source.svg](/Users/gb/Projects/bDS2/priv/desktop/macos/icon-source.svg)
and committed under `priv/desktop/macos/`. Pass `--regen-icon` to rebuild it.

### 2. Register the `bds2://` scheme (optional)

`--register` tells LaunchServices about the scheme without moving the app to
`/Applications` — useful for testing blogmark deep links locally:

```bash
mix bds.bundle.macos --app-release _build/prod/rel/bds --register
```

### Run / smoke-test

```bash
open dist/macos/BDS2.app
open "bds2://new-post?title=Hello&url=https://example.com"   # opens a draft
```

### Useful flags

- `--app-release PATH` — release dir to wrap (default `_build/<env>/rel/bds`).
- `--output DIR` — output directory (default `dist/macos`).
- `--version V` — version string for `Info.plist` (default from `mix.exs`).
- `--regen-icon` — regenerate `AppIcon.icns` from the source SVG.
- `--register` — register the `bds2://` scheme via LaunchServices.
- `--no-codesign` — skip the ad-hoc codesign step.

### Verifying the bundle

```bash
plutil -lint dist/macos/BDS2.app/Contents/Info.plist
codesign --verify --deep --strict dist/macos/BDS2.app
# no /opt/homebrew or /usr/local references should appear:
otool -L dist/macos/BDS2.app/Contents/Resources/rel/lib/wx-*/priv/wxe_driver.so
```
