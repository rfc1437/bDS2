# bDS2 Plan

This document tracks the current implementation state of bDS2 against the Allium specs and the old bDS application, and it defines the ordered plan to reach full feature parity.

## Current State

The rewrite already implements most of the backend and compatibility-critical surface described by the specs.

### Implemented Now

- Foundation and persistence: OTP app startup, Ecto repo, migrations, and persisted tables for projects, posts, translations, media, tags, templates, scripts, settings, chat, AI catalog data, embeddings, imports, publishing jobs, MCP proposals, and CLI notifications.
- Compatibility-critical file contracts: post frontmatter, media sidecars, thumbnail layout, template and script frontmatter, menu OPML, metadata diff, and rebuild-from-filesystem flows.
- Compatibility parity locks: executable parity coverage now pins the old-bDS behavior for serializer/file contracts, metadata-diff ordering, canonical generation routes, feed output, localized archive rendering, preview draft language selection, taxonomy archive links, and media URL rewriting.
- Core editorial domains: projects, posts, post translations, media, media translations, tags, templates, scripts, menu data, and project metadata.
- Output and infrastructure: search, Liquid rendering, site generation, preview server, publishing, background tasks, i18n, git support, MCP server, AI operations, embeddings, and CLI sync.
- Desktop shell foundation: native menu definitions, LiveView shell endpoint, activity bar, sidebar views, tab/workbench state, task panel, assistant sidebar, status bar, project switcher, shell command routing, template-backed shell rendering, sidebar search/filter/load-more controls, dashboard recent-post opening, UI language switching, project dropdown actions, output/post-link/git lower-panel content, browser-native menu bridging, and the shared modal/overlay layer for AI suggestions, picker flows, confirmations, and gallery/lightbox interactions.

### Implemented But Not Yet At Parity

- Layout, tabs, and sidebar shell behavior exist, but many editor routes still render generic content instead of feature-complete editors.
- Maintenance and validation routes such as metadata diff, site validation, translation validation, and duplicate detection have dedicated payload renderers, but most authoring routes do not.
- AI gating, translation, image analysis, tag suggestions, and side-effect chains exist in backend services, but the end-to-end UI flows around those operations are still incomplete.
- Shared workbench/session state exists, but the richer cross-surface behaviors described in the UI data-flow specs are only partially realized.

### Missing Or Materially Incomplete

- Rich route-specific editors for post, media, settings, tags, chat, script, template, and misc surfaces.
- Full UI wiring for create/import/publish/preview/edit-menu flows described by the editor specs.
- Full parity validation against the old application for every spec-defined edge case in editor behavior, media processing details, and cross-feature action chains.

## Spec Coverage Snapshot

Ordered from base contracts upward:

| Area | Specs | Status | Notes |
| --- | --- | --- | --- |
| Persistence and file contracts | `schema`, `frontmatter`, `project`, `post`, `translation`, `media`, `tag`, `template`, `script`, `menu`, `metadata` | Implemented | Core schemas, file formats, publish flows, sidecars, rebuild, and metadata diff are present and tested. |
| Rendering and output pipelines | `template_context`, `search`, `generation`, `preview`, `publishing`, `task`, `i18n` | Implemented | Rendering, generation, preview, publishing, task tracking, and localization are in place. |
| Integrations | `git`, `mcp`, `ai`, `embedding`, `cli_sync`, `metadata_diff` | Implemented | Service layer and test coverage exist for these domains. |
| Desktop shell primitives | `layout`, `tabs`, `sidebar_views` | Implemented | Route state, registry-backed sidebar/editor coverage, panel fallback rules, menu/native-command wiring, and a LiveView-owned shell frame are in place; route bodies remain generic until the editor UX phase. |
| Cross-cutting flows | `ui_data_flow`, `engine_side_effects`, `action_patterns`, `media_processing` | Partial | Most backend behavior exists, but UI coordination, explicit engine event modeling, and some parity details are still incomplete. |
| Editor UX layer | `editor_post`, `editor_media`, `editor_settings`, `editor_tags`, `editor_chat`, `editor_script`, `editor_template`, `editor_misc`, `modals` | Partial | Shared modal workflows are implemented; route registration exists, but feature-complete editors are not done. |

## Plan To Full Feature Parity

The remaining work needs to proceed from base contracts upward. Later phases should not outrun the lower layers they depend on.

1. Lock compatibility contracts. Completed 2026-04-25.
   Schema, frontmatter, sidecars, template context, generation output, preview behavior, metadata diff, and rebuild behavior are now pinned against the Allium specs and the old bDS application with executable parity tests.

2. Close engine-level behavior gaps. Completed 2026-04-25.
   Save/publish/delete side-effects, published-post `templateSlug` frontmatter rewrites, manual-translation source-post reopening, post-to-media sidecar cleanup, auto-translation task cascades, linked-media translation cascades, link graph maintenance, thumbnail regeneration rules, and rebuild notifications are now implemented and covered at the backend layer independent of UI.

3. Finish the desktop shell primitives. Completed 2026-04-26.
   Route state, registry-backed shell command coverage, panel fallback integration, menu/native-command wiring, template-backed LiveView rendering, sidebar search/filter/load-more controls, dashboard recent-post opening, project dropdown actions, UI language switching, real output/post-link/git lower-panel content, and native-menu event bridging now cover the old shell frame behavior while preserving the legacy layout and styling.

4. Implement the shared modal and confirmation layer. Completed 2026-04-26.
   The LiveView shell now owns the shared modal/overlay system required by the specs: AI suggestions, delete confirmations, merge confirmation, picker overlays, and gallery/lightbox flows, with overlay state isolated in a pure module and covered by focused tests.

5. Build feature-complete editors.
   Replace generic editor bodies with real editors for posts, media, settings, tags, chat, scripts, templates, and misc maintenance views, including save/discard/publish/delete/import flows.

6. Wire cross-surface UI behavior.
   Complete the sidebar-editor-tab-reactivity model, dirty-state rules, background task feedback, offline/airplane-mode gating in the UI, and route-specific state transitions described by the UI data-flow and action-pattern specs.

7. Reach legacy parity and harden releases.
   Add executable tests mapped to the Allium specs and old-app behaviors, then validate packaging, desktop runtime behavior, MCP packaging, and end-to-end workflows as release criteria.
