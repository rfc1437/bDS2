# Tailwind And Phoenix Asset Tooling For bDS2 Desktop

## Purpose

This document describes the target styling architecture for a Tailwind-integrated Phoenix LiveView desktop app in this repository.

It is written as a handoff for a coding agent that will perform the implementation.

This is not a migration guide from a public web app. It is a target-state guide for a Phoenix LiveView desktop shell with local assets, dense editor surfaces, overlays, resizable panes, and desktop-specific titlebar behavior.

## Verified Current State

The current app does not use the default Phoenix asset pipeline.

- CSS is served directly from `priv/ui/app.css`.
- JS is served directly from `priv/ui/live.js`.
- Static assets are served from `priv/ui` in `lib/bds/desktop/endpoint.ex`.
- The root layout links `/assets/app.css` in `lib/bds/desktop/layouts.ex`, but that path is currently backed by `priv/ui/app.css`, not by generated Phoenix assets.
- There is no `:tailwind` or `:esbuild` setup in `mix.exs`.

Relevant files:

- `lib/bds/desktop/endpoint.ex`
- `lib/bds/desktop/layouts.ex`
- `mix.exs`
- `priv/ui/app.css`
- `priv/ui/live.js`

## Official Phoenix Facts

The implementation target should follow Phoenix defaults where they fit the desktop shell.

Official Phoenix references:

- Phoenix Asset Management: https://hexdocs.pm/phoenix/asset_management.html
- Phoenix Components and HEEx: https://hexdocs.pm/phoenix/components.html
- Phoenix.Component reference: https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html

Facts from Phoenix docs and generator templates:

- Phoenix v1.7+ defaults to Tailwind for CSS and esbuild for JS.
- The default CSS source entrypoint is `assets/css/app.css`.
- The default generated CSS output is `priv/static/assets/css/app.css`.
- The default generated JS output is `priv/static/assets/js/app.js`.
- Phoenix promotes function components and HEEx as the main rendering model.
- Phoenix does not prescribe per-component CSS modules. Tailwind-first HEEx plus shared source CSS is a valid Phoenix-default shape.

## Target Outcome

The target outcome is a solid Phoenix-default asset setup with Tailwind as the main styling system and a generated production stylesheet.

The target should look like this:

- Tailwind source lives in `assets/css/app.css` and imported CSS modules.
- The final stylesheet is generated into `priv/static/assets/css/app.css`.
- LiveView JS entrypoint lives in `assets/js/app.js` and builds to `priv/static/assets/js/app.js`.
- The desktop endpoint serves static assets from `priv/static`.
- Layouts reference the generated CSS and JS outputs.
- HEEx markup carries most layout, spacing, typography, responsive, and state classes.
- Authored CSS remains for global tokens, app-region behavior, pseudo-elements, scrollbars, Monaco integration, hard selectors, and overlay mechanics.

## Architecture Rules

### 1. Tailwind Owns The Common Case

Use Tailwind utility classes directly in HEEx for:

- flex and grid layout
- spacing
- typography
- borders and radii
- colors and opacity
- active, selected, disabled, and hover states
- responsive breakpoints
- overflow and truncation

Do not preserve large semantic wrapper classes when they only encode simple layout decisions.

Good examples to move into HEEx classes:

- tab rows
- button rows
- editor header layout
- metadata field layout
- sidebar list row spacing
- status bar item alignment

### 2. Authored CSS Owns The Desktop-Specific Case

Keep authored CSS source files for:

- `app-region` and `-webkit-app-region`
- pseudo-elements used for icons, handles, and active markers
- custom scrollbars
- Monaco/editor iframe or host integration
- absolute overlay stacks and backdrops
- drag and drop affordances
- complex attribute selectors
- hard-to-read repeated combinations that should become shared component classes

Do not force these into giant utility strings if readability drops.

### 3. Keep A Thin Semantic CSS Layer

It is acceptable to keep a small number of semantic component classes when they encode a repeated desktop UI primitive.

Examples of valid semantic classes in the target state:

- `.window-titlebar`
- `.resizable-panel-divider`
- `.overlay-root`
- `.monaco-host`
- `.panel-entry`
- `.btn-base`, `.btn-theme-primary`, `.btn-theme-danger`

These classes should be implemented in Tailwind source CSS using `@layer components` and should remain small, stable, and reusable.

### 4. Tokens Must Be Centralized

The current stylesheet relies heavily on VS Code-like CSS variables. Preserve that idea.

The new `assets/css/app.css` must define the design tokens once, using Tailwind v4 `@theme` plus any required raw CSS custom properties for runtime-driven values.

Examples from the current app that must survive:

- shell/background colors
- tab active/inactive colors
- status bar colors
- focus border color
- input background and border colors
- sidebar width
- assistant width
- font family and font size

### 5. Desktop Layout Constraints Must Stay Intact

The styling rewrite must preserve these runtime constraints:

- the app occupies full window width and height
- the shell uses `overflow: hidden` at the top level
- the main workbench uses `min-height: 0` and `min-width: 0` correctly
- resizable sidebars remain width-variable
- titlebar remains draggable except for interactive controls
- overlays render above the shell without breaking keyboard focus or pointer behavior

## Proposed Asset Layout

Use the standard Phoenix asset layout.

```text
assets/
  css/
    app.css
    shell.css
    sidebar.css
    tabs.css
    editor.css
    forms.css
    overlays.css
    panel.css
    assistant.css
    menu_editor.css
    media_editor.css
    utilities.css
  js/
    app.js
    ...
priv/
  static/
    assets/
      css/
      js/
```

Recommended responsibilities:

- `assets/css/app.css`: Tailwind import, `@source`, tokens, base layer, imports
- `assets/css/shell.css`: app shell, titlebar, activity bar, pane shells, status bar
- `assets/css/sidebar.css`: sidebar filters, search, chips, calendar tree, load more
- `assets/css/tabs.css`: workbench tabs and editor tabs
- `assets/css/editor.css`: common editor frame, toolbar, meta column, shared form shell
- `assets/css/forms.css`: shared input, textarea, tag chip, picker, inline action primitives
- `assets/css/overlays.css`: overlay root, modal backdrop, dialog shells, gallery/lightbox
- `assets/css/panel.css`: panel tabs, panel entry cards, tasks, output, git log
- `assets/css/assistant.css`: assistant sidebar and chat-specific shared surfaces
- `assets/css/menu_editor.css`: menu tree, drag/drop indicators, picker lists
- `assets/css/media_editor.css`: media preview, linked post picker, detail forms
- `assets/css/utilities.css`: a very small set of custom utilities that are truly reused

## Proposed Phoenix Asset Tooling

The implementation should introduce the standard Phoenix aliases and configs.

### mix.exs

Add:

- `{:tailwind, "~> 0.3", runtime: Mix.env() == :dev}`
- `{:esbuild, "~> 0.10", runtime: Mix.env() == :dev}`

Add aliases similar to:

- `assets.setup`
- `assets.build`
- `assets.deploy`

### Versioning (mandatory)

The Elixir `:tailwind` wrapper still defaults to Tailwind v3. The plan in this document assumes **Tailwind v4** syntax (`@import "tailwindcss"`, `@theme`, `@source`, `@layer components`). Pin both tools explicitly in `config/config.exs`:

- `config :tailwind, version: "4.1.14"` (or current 4.1.x)
- `config :esbuild, version: "0.25.4"` (or current 0.25.x)

Without an explicit v4 pin the build will silently install Tailwind v3 and v4 directives will not resolve.

### No Node.js policy

The Elixir `:tailwind` and `:esbuild` wrappers download self-contained binaries and do **not** require Node.js. The implementation MUST stay Node-free unless a third-party Tailwind plugin is later required (in which case the custom `assets/build.js` route from the Phoenix asset_management guide is used). No `package.json` is added under `assets/`.

### config/config.exs

Configure Tailwind input and output paths.

Target output:

- `assets/css/app.css` -> `priv/static/assets/css/app.css`

Configure esbuild for:

- `assets/js/app.js` -> `priv/static/assets/js/app.js`

esbuild profile must include `--bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*` and `nodePaths: [Mix.Project.build_path() <> "/../../deps"]` so `phoenix`, `phoenix_html`, and `phoenix_live_view` resolve from `deps/` without an `npm install`.

### config/dev.exs

Add Phoenix watchers for:

- Tailwind `--watch`
- esbuild `--watch`

### No phx.digest in desktop builds

This is a desktop app served through an embedded WebView, not a public web app behind a CDN.

- Do NOT run `mix phx.digest` as part of `assets.deploy`.
- Output filenames stay stable (`app.css`, `app.js`) so the layout can link them by fixed path.
- `assets.deploy` for this repo is: `tailwind default --minify`, `esbuild default --minify`. Nothing else.

### endpoint/layout changes

Update the desktop endpoint and root layout to serve and link generated assets from `priv/static/assets` instead of `priv/ui`.

Specifically:

- Replace the existing `Plug.Static` for `/assets` with `from: {:bds, "priv/static/assets"}` and `only` listing the generated `css` and `js` directories.
- Drop the `/vendor/phoenix` and `/vendor/live_view` `Plug.Static` blocks; those scripts are now bundled by esbuild from `deps/`.
- Add a dedicated `Plug.Static` for `/monaco` pointing at `priv/ui/monaco` (or move it to `priv/static/monaco`). Monaco is a prebuilt vendor drop and MUST NOT be passed through esbuild.
- Remove the `<script src="/vendor/phoenix/...">` and `<script src="/vendor/live_view/...">` tags from `lib/bds/desktop/layouts.ex`. Keep only `/assets/app.css` and `/assets/app.js`.

## JS Pipeline

The JS pipeline mirrors the CSS pipeline.

### Entrypoint

`assets/js/app.js` is the single esbuild entrypoint. It:

- imports `phoenix`, `phoenix_html`, and `phoenix_live_view` (resolved from `deps/` via esbuild `nodePaths`)
- constructs the `LiveSocket` with the desktop CSRF token
- registers all hooks currently defined inline in `priv/ui/live.js`
- wires the native menu / titlebar / shortcut bridges

### Module layout

Split the current `priv/ui/live.js` (1.4k lines) into focused modules under `assets/js/`:

- `assets/js/app.js` - entrypoint, LiveSocket, hook registration
- `assets/js/hooks/` - one file per hook
- `assets/js/bridges/` - native menu, titlebar, shortcut bridges
- `assets/js/monaco/` - thin host glue only; do NOT bundle Monaco itself

### Monaco carve-out

Monaco is loaded as prebuilt assets from `/monaco/...` and is not part of the esbuild graph. The host glue in `assets/js/monaco/` only configures the loader URL and posts messages; it does not `import` Monaco modules.

### Vendor stripping

After the switch:

- `priv/ui/app.css` is deleted (its content has been redistributed under `assets/css/`).
- `priv/ui/live.js` is deleted.
- `priv/ui/monaco/` stays (or moves to `priv/static/monaco/`).
- The `phoenix` and `phoenix_live_view` dep static drops are no longer served.

## Iconography

The app keeps its existing **inline SVG** icon set. Do NOT adopt the Phoenix 1.8 Heroicons-via-Tailwind-plugin pattern.

Reasons:

- The target visual look is defined by the current bDS UI; its icons are part of that look.
- Inline SVG keeps icons under direct control for sizing, stroke, and currentColor styling via Tailwind utility classes.
- Avoiding the Heroicons git dep keeps the build Node-free and dependency-light.

Rules:

- Existing SVG icons stay where they are (HEEx components / inline `<svg>` markup).
- Icon size and color are controlled by Tailwind utilities on the wrapping element (`size-4`, `text-[var(--color-icon)]`, etc.) using `fill="currentColor"` or `stroke="currentColor"`.
- No `:heroicons` mix dep, no Tailwind icon plugin, no `assets/vendor/heroicons.js`.
- If a new icon is needed, add the SVG inline in the appropriate component module.

## HEEx Styling Strategy

### Prefer Utility Classes In Templates

Use utility classes in HEEx for:

- shell flex layout
- editor content spacing
- section stacks
- truncation and overflow
- standard button alignment
- grid column changes at breakpoints
- selected and hovered states that are directly tied to assign state

### Keep Dynamic Class Lists Explicit

LiveView templates should build classes with arrays where state is already in assigns.

Example pattern:

```elixir
class={[
  "flex items-center gap-2 px-3 py-2 text-sm",
  selected? && "bg-[var(--color-selected-bg)] text-white",
  disabled? && "opacity-50 pointer-events-none"
]}
```

### Do Not Hide Structure Behind Giant Custom Class Trees

Avoid re-creating the current `app.css` by keeping every nested selector and merely moving it into `assets/css`.

If a selector exists only because the old CSS owned all layout, move that responsibility into HEEx.

## Tailwind Source Conventions

### app.css

`assets/css/app.css` should use Tailwind v4 import syntax.

`source(none)` disables Tailwind's automatic content detection so only directories listed via `@source` are scanned. Every directory that ships HEEx or class strings MUST be listed. Audit `lib/` for additional renderers (preview, generation, MCP surfaces) and add `@source` lines for any that emit class names consumed at build time.

Runtime-driven values (e.g. resizable panel widths that change via CSS variable assignment from JS) MUST stay as plain CSS custom properties under `:root` or a scoped selector. `@theme` values are baked at build time and are not appropriate for values mutated at runtime. Use `@theme` for stable design tokens (colors, font sizes, spacing scale extensions) that should produce utility classes; use `:root { --foo: … }` for everything that the app writes to at runtime.

Suggested structure:

```css
@import "tailwindcss" source(none);

@source "../css";
@source "../js";
@source "../../lib/bds/desktop";

@theme {
  /* app tokens */
}

@layer base {
  /* html, body, root shell defaults */
}

@import "./shell.css";
@import "./sidebar.css";
@import "./tabs.css";
@import "./editor.css";
@import "./forms.css";
@import "./panel.css";
@import "./assistant.css";
@import "./overlays.css";
@import "./menu_editor.css";
@import "./media_editor.css";
@import "./utilities.css";
```

### Component CSS Rules

When writing component CSS in imported files:

- use `@layer components` for shared semantic classes
- use `@layer utilities` only for narrowly reusable custom utilities
- keep selectors shallow
- avoid giant descendant chains unless required by generated HTML structure or overlay mechanics
- prefer `@apply` sparingly and only for stable component classes, not as a substitute for writing HEEx utilities

## Current UI Structure Reference

The implementation agent must use the current monolith as a source map, not as the final architecture.

The current stylesheet is `priv/ui/app.css` and is approximately 8.5k lines.

Use the following region map when carrying styling over.

### Current app.css region map

- Lines `1-140`: root variables, base element reset, buttons, top-level shell defaults
- Lines `141-415`: app shell and window titlebar
  - `.app`, `.app-main`, `.app-content`
  - `.window-titlebar*`
- Lines `416-623`: activity bar and sidebar shells
  - `.activity-bar*`
  - `.sidebar-shell*`, `.assistant-sidebar-shell*`
  - `.sidebar*`, `.assistant-sidebar*`
  - `.resizable-panel-divider`
- Lines `624-812`: workbench tab bar
  - `.tab-bar*`, `.tab*`
- Lines `813-1100`: shared editor shell and editor tabs
  - `.editor-shell`, `.editor-frame`, `.editor-main`, `.editor-meta`
  - `.editor-toolbar*`
  - `.post-editor .editor-header`, `.editor-tabs`, `.editor-tab*`
- Lines `1100-1700`: post editor forms and metadata/media panel
  - `.post-editor .editor-content`
  - `.post-editor .editor-field*`
  - `.post-editor .post-editor-input`, `.post-editor-textarea`
  - `.tag-input*`, `.tag-chip*`
  - media insertion and post media list
- Line `1691` onward: first responsive collapse for editor/media layout
- Lines `1736-1833`: early shell/gallery overlay and insert-media grid rules
- Lines `1833+`: more mobile/narrow viewport adjustments
- Lines `1950-2263`: status bar and shell footer controls
  - `.status-bar*`
  - `.project-selector*`
- Lines `2264-2599`: overlay root and modal system
  - `.overlay-root`
  - `.ai-suggestions-modal*`
  - `.insert-modal*`
  - `.language-picker-modal*`
  - `.confirm-delete-modal*`
  - `.gallery-overlay*`
- Lines `2600-2876`: menu editor
  - `.menu-editor-*`
- Lines `2889+`: media editor
  - `[data-testid="media-editor"] *`
- Lines `3458+`: style/theme picker surface
  - `.style-theme-*`
- Lines `4958`, `6722`, `8268`, `8514`: later breakpoint-specific adjustments for desktop shell and advanced editors

Treat those ranges as source material to be redistributed into the new Tailwind source layout.

## Current HEEx And Component Surface Reference

The styling rewrite needs to move with the component structure, not only with CSS selectors.

Important current rendering surfaces:

- `lib/bds/desktop/shell_live.ex`
  - top-level workbench render entry
- `lib/bds/desktop/shell_live/sidebar_components.ex`
  - sidebar search, archive tree, tag/category chips, nav/settings lists, load more
- `lib/bds/desktop/shell_live/panel_renderer.ex`
  - tasks, output, git log, panel toolbars
- `lib/bds/desktop/shell_live/post_editor.ex`
  - post editor render surface
- `lib/bds/desktop/shell_live/media_editor.ex`
  - media editor render surface
- `lib/bds/desktop/shell_live/script_editor.ex`
  - script editor render surface
- `lib/bds/desktop/shell_live/template_editor.ex`
  - template editor render surface
- `lib/bds/desktop/shell_live/chat_editor.ex`
  - assistant/chat surface
- `lib/bds/desktop/shell_live/menu_editor.ex`
  - menu editor tree surface

Implementation rule:

- move simple layout and state styling into these HEEx/component surfaces
- keep authored CSS for shared primitives and complex desktop behavior

## Desktop-Specific Styling Rules

The app is a desktop shell, not a normal browser page.

The implementation must preserve:

- draggable titlebar regions
- non-draggable controls inside the titlebar
- local, app-like split-pane behavior
- fixed-height titlebar, tabs, and status bar rails
- overlay stacking over the shell
- editor and sidebar widths controlled by CSS variables where appropriate
- visual parity for assistant/sidebar/panel open and closed states

Do not optimize for tiny public web payloads at the expense of shell clarity.
Do optimize for maintainability, explicit component ownership, and predictable desktop behavior.

## Implementation Phases

### Phase 0: Tests And Validation Baseline

- Add a smoke test that requests `/assets/app.css` and `/assets/app.js` and asserts a 200 with non-empty body served from `priv/static/assets`.
- Add a render snapshot test for the top-level shell HEEx so class-string regressions during the rewrite are caught.
- Establish that every phase ends with clean `mix compile --warnings-as-errors`, `mix test`, and `mix dialyzer` runs (per repo AGENTS.md).

### Phase 1: Install Phoenix Asset Tooling

- add Tailwind and esbuild dependencies
- create `assets/css/app.css` and `assets/js/app.js`
- configure `config/config.exs`, `config/dev.exs`, and `mix.exs`
- switch endpoint/layouts to generated assets
- keep current visuals as close as possible

### Phase 2: Split The Monolith Into Source Modules

- move the current `priv/ui/app.css` into the proposed `assets/css/*.css` modules
- keep selectors mostly intact at first
- copy raw selectors only; do NOT rewrite to `@apply` in this phase
- defer all `@apply` and utility-extraction decisions to Phase 3
- verify the desktop shell still renders correctly

### Phase 3: Move Common Layout Into HEEx

- rewrite top-level shell markup, tabs, headers, and common forms to use Tailwind classes directly
- reduce selector nesting
- keep only the thin semantic CSS layer

### Phase 4: Normalize Shared Primitives

- standardize buttons
- standardize inputs and textareas
- standardize tabs and badges
- standardize panel entries and empty states

### Phase 5: Finish Desktop-Specific Surfaces

- overlays
- menu editor drag/drop states
- media preview/detail layouts
- assistant/chat surfaces
- narrow viewport behavior

## Acceptance Criteria

The rewrite is successful when:

- assets are built through Phoenix default tooling
- the desktop endpoint serves generated assets from `priv/static`
- the visual shell matches the existing app closely enough for feature work to continue
- the current `priv/ui/app.css` is no longer the source of truth
- the new styling is split into source modules with clear ownership
- HEEx markup owns common layout and state classes
- authored CSS is limited to tokens, desktop primitives, and complex selectors
- Tailwind v4 and esbuild versions are explicitly pinned in `config/config.exs`
- no Node.js / `package.json` is introduced under `assets/`
- no `mix phx.digest` step exists; generated asset filenames remain stable
- inline SVG iconography from the existing UI is preserved (no Heroicons dep)
- `mix compile --warnings-as-errors`, `mix test`, and `mix dialyzer` are clean after every phase

## Non-Goals

These are not goals of the rewrite:

- blindly replacing every old class with utilities in one pass
- preserving the exact old selector tree
- introducing CSS modules or a React-style styling system
- optimizing for generic web landing-page concerns
- changing product behavior unrelated to styling and asset delivery

## Guidance For The Coding Agent

When implementing this plan:

- start by wiring Phoenix asset tooling, not by rewriting 8k lines of CSS in place
- preserve runtime behavior first, then simplify
- move layout decisions to HEEx only when they become clearer there
- keep desktop-specific mechanics in CSS
- use the current `priv/ui/app.css` region map as a source index, not as a blueprint for the final architecture
