# bDS2 Plan

This document tracks the current implementation state of bDS2 against the Allium specs and the old bDS application.

## Open Work Summary

- Completed plan steps: 1, 2, 3, 4, 5, 6, 7, 8, 9.
- Open plan steps: 10, 11, 12.
- Next actionable step: 10. The batch-3 and batch-4 parity backlog is now closed, so the next implementation work is menu editor parity on the existing menu data model.
- Scheduled after the current parity pass: 11 desktop-side CLI mutation watching, 12 import execution/editor parity.

## Current State

The rewrite already implements most of the backend and compatibility-critical surface described by the specs.

### Implemented Now

- Foundation and persistence: OTP app startup, Ecto repo, migrations, and persisted tables for projects, posts, translations, media, tags, templates, scripts, settings, chat, AI catalog data, embeddings, imports, publishing jobs, MCP proposals, and CLI notifications.
- Compatibility-critical file contracts: post frontmatter, media sidecars, thumbnail layout, template and script frontmatter, menu OPML, metadata diff, and rebuild-from-filesystem flows.
- Compatibility parity locks: executable parity coverage now pins the old-bDS behavior for serializer/file contracts, metadata-diff ordering, canonical generation routes, feed output, localized archive rendering, preview draft language selection, taxonomy archive links, and media URL rewriting.
- Core editorial domains: projects, posts, post translations, media, media translations, tags, templates, scripts, menu data, and project metadata.
- Output and infrastructure: search, Liquid rendering, site generation, preview server, publishing, background tasks, i18n, git support, MCP server, AI operations, embeddings, and CLI sync.
- Desktop shell foundation: native menu definitions, LiveView shell endpoint, activity bar, sidebar views, tab/workbench state, task panel, assistant sidebar, status bar, project switcher, shell command routing, template-backed shell rendering, sidebar search/filter/load-more controls, dashboard recent-post opening, UI language switching, project dropdown actions, output/post-link/git lower-panel content, browser-native menu bridging, and the shared modal/overlay layer for AI suggestions, picker flows, confirmations, and gallery/lightbox interactions.
- Dedicated editor surfaces now exist for posts, media, settings, style, tags, scripts, templates, chat, and the misc maintenance views, with focused shell-live tests covering real rendering and core save/preview/publish flows.

### Implemented But Not Yet At Parity

- The currently implemented batch-3 and batch-4 surfaces now score green in this plan snapshot; follow-on work should come only from later missing-feature tracks or newly proven drift.
- Shared workbench/session state exists, but any future UI-data-flow work should now be treated as a concrete parity gap only when it can be tied back to a proven old-app behavior.

### Missing Or Materially Incomplete

- Import remains definition-only: stored import definitions exist, but the old WXR analysis/execution pipeline and its dedicated editor surface are not present.
- Menu data exists, but the `menu_editor` route still lacks a dedicated editor surface comparable to the old app.
- CLI sync notification persistence exists, but old-app parity for desktop-side watching/broadcasting of external DB mutations is not yet proven.
- The remaining parity write-up gap is now keeping the chat row and the final minimal backlog in sync with the current implementation.

## Spec Coverage Snapshot

Ordered from base contracts upward:

| Area | Specs | Status | Notes |
| --- | --- | --- | --- |
| Persistence and file contracts | `schema`, `frontmatter`, `project`, `post`, `translation`, `media`, `tag`, `template`, `script`, `menu`, `metadata` | Implemented | Core schemas, file formats, publish flows, sidecars, rebuild, and metadata diff are present and tested. |
| Rendering and output pipelines | `template_context`, `search`, `generation`, `preview`, `publishing`, `task`, `i18n` | Implemented | Rendering, generation, preview, publishing, task tracking, and localization are in place. |
| Integrations | `git`, `mcp`, `ai`, `embedding`, `cli_sync`, `metadata_diff` | Implemented | Service layer and test coverage exist for these domains. |
| Desktop shell primitives | `layout`, `tabs`, `sidebar_views` | Implemented | Route state, registry-backed sidebar/editor coverage, panel fallback rules, menu/native-command wiring, and a LiveView-owned shell frame are in place. |
| Cross-cutting flows | `ui_data_flow`, `engine_side_effects`, `action_patterns`, `media_processing` | Partial | Most backend behavior exists, but UI coordination, explicit engine event modeling, and some parity details are still incomplete. |
| Editor UX layer | `editor_post`, `editor_media`, `editor_settings`, `editor_tags`, `editor_chat`, `editor_script`, `editor_template`, `editor_misc`, `modals` | Partial | The existing editor routes now render dedicated surfaces and have focused tests; import/menu parity and full old-app behavior scoring are still outstanding. |

## Batch 3 And 4 Focus

Only these two audit tracks matter for the current pass. The follow-on missing-feature tracks now sit explicitly after this pass as steps 10, 11, and 12.

1. Lock compatibility contracts. Completed 2026-04-25.
   Schema, frontmatter, sidecars, template context, generation output, preview behavior, metadata diff, and rebuild behavior are now pinned against the Allium specs and the old bDS application with executable parity tests.

2. Close engine-level behavior gaps. Completed 2026-04-25.
   Save/publish/delete side-effects, published-post `templateSlug` frontmatter rewrites, manual-translation source-post reopening, post-to-media sidecar cleanup, auto-translation task cascades, linked-media translation cascades, link graph maintenance, thumbnail regeneration rules, and rebuild notifications are now implemented and covered at the backend layer independent of UI.

3. Finish the desktop shell primitives. Completed 2026-04-26.
   Route state, registry-backed shell command coverage, panel fallback integration, menu/native-command wiring, template-backed LiveView rendering, sidebar search/filter/load-more controls, dashboard recent-post opening, project dropdown actions, UI language switching, real output/post-link/git lower-panel content, and native-menu event bridging now cover the old shell frame behavior while preserving the legacy layout and styling.

4. Implement the shared modal and confirmation layer. Completed 2026-04-26.
   The LiveView shell now owns the shared modal/overlay system required by the specs: AI suggestions, delete confirmations, merge confirmation, picker overlays, and gallery/lightbox flows, with overlay state isolated in a pure module and covered by focused tests.

5. Audit batch 3: shell UI plus all dedicated editors already present. Completed 2026-04-28.
   Compared the old Electron/React shell and each dedicated editor route against the current LiveView shell, scored parity green/yellow/red, and reduced the proven batch-3 drift list to the remaining chat-surface gaps only.

6. Audit batch 4: lower-risk backend and integration services behind those surfaces. Completed 2026-04-29.
   Tied each old engine contract to its bDS2 replacement, verified the executable proof set, probed the relevant owning UI/editor entry points, and recorded the batch-4 parity scores in the snapshot below.

7. Restore remaining chat editor parity on the implemented route. Completed 2026-04-29.
   Re-ran the focused chat parity pass against the old `ChatPanel`/`ChatTranscript` surface, closed the remaining in-flight input-state drift on the implemented route, and refreshed the parity row to green without widening into backend streaming work.

8. Restore misc maintenance editor parity on the implemented routes. Completed 2026-04-28.
   Translation validation now uses the old dedicated validate-and-fix card surface again, and git diff now renders through the structured Monaco diff viewer while keeping the current metadata-diff, site-validation, and duplicate flows intact.

9. Fix any remaining batch 3 and batch 4 parity gaps that the audit proves. Completed 2026-04-29.
   No further proven batch-3 or batch-4 gaps remained after the focused chat parity pass, so the minimal backlog now begins with the later menu, CLI-mutation-watching, and import tracks.

10. Restore menu editor parity on the implemented data model.
   Build the dedicated menu editor surface against the existing menu data using the old app as the blueprint for workflow, behavior, UI structure, and styling.

11. Restore desktop-side CLI mutation watching parity.
   Add the old desktop-side watching and invalidation behavior for external database mutations so CLI sync notifications propagate through the shell with the same timing and UX expectations as the old app.

12. Restore import execution and editor parity.
   Extend the existing stored import definitions into the old WXR analysis/execution pipeline and add the dedicated editor surface so import behavior, workflow, and look and feel match the old app.

## Batch 3 Audit Matrix

| Slice | Old bDS anchor | bDS2 anchor | Audit questions |
| --- | --- | --- | --- |
| Shell chrome | `src/renderer/components/ActivityBar`, `Sidebar`, `TabBar`, `Panel`, `WindowTitleBar`, `AssistantSidebar`, `App.tsx`, `App.css` | `lib/bds/desktop/shell_live.ex`, `lib/bds/desktop/shell_live/index.html.heex`, `lib/bds/ui/workbench.ex`, `lib/bds/desktop/shell_live/sidebar_components.ex`, `priv/ui/app.css` | Same activity ordering, same toggle semantics, same transient/pinned tab behavior, same panel fallback rules, same project switcher behavior, same language switching, same titlebar/menu behavior, same shell sizing defaults. |
| Post editor | `src/renderer/components/Editor/PostEditor.tsx` | `lib/bds/desktop/shell_live/post_editor.ex`, `lib/bds/desktop/shell_live/post_editor_html` | Same draft/published body loading, save/publish/discard/delete rules, preview switching, quick actions, translation flags, media panel, dirty-state behavior, localized labels. |
| Media editor | `src/renderer/components/Editor/MediaEditor.tsx` | `lib/bds/desktop/shell_live/media_editor.ex`, `lib/bds/desktop/shell_live/media_editor_html` | Same explicit-save flow, same linked-post rendering, same translation modal/edit path, same quick actions, same metadata fields and localization. |
| Settings editor | `src/renderer/components/SettingsView/SettingsView.tsx` | `lib/bds/desktop/shell_live/settings_editor.ex`, `lib/bds/desktop/shell_live/settings_editor_html/settings_editor.html.heex` | Same section model, same search/filter behavior, same section targeting, same metadata fields, same AI/settings grouping, same publishing/data/MCP sections. |
| Style editor | `src/renderer/components/StyleView/StyleView.tsx` | `lib/bds/desktop/shell_live/settings_editor.ex`, `lib/bds/desktop/shell_live/settings_editor_html/style_editor.html.heex` | Same theme list, same preview URL behavior, same apply flow, same selected/applied theme semantics. |
| Tags editor | `src/renderer/components/TagsView/TagsView.tsx` | `lib/bds/desktop/shell_live/tags_editor.ex`, `lib/bds/desktop/shell_live/tags_editor_html` | Same tag CRUD, same color handling, same merge/delete flows, same post-template selection behavior. |
| Script editor | `src/renderer/components/ScriptsView/ScriptsView.tsx` | `lib/bds/desktop/shell_live/code_entity_editor.ex`, `lib/bds/desktop/shell_live/code_entity_editor_html/script_editor.html.heex` | Same script metadata fields, same Monaco setup, same check/run/save/delete flow, same entrypoint discovery behavior. |
| Template editor | `src/renderer/components/TemplatesView/TemplatesView.tsx` | `lib/bds/desktop/shell_live/code_entity_editor.ex`, `lib/bds/desktop/shell_live/code_entity_editor_html/template_editor.html.heex` | Same template metadata fields, same Monaco setup, same validate/save/delete flow, same template kind handling. |
| Chat editor | `src/renderer/components/ChatPanel/ChatPanel.tsx` | `lib/bds/desktop/shell_live/chat_editor.ex`, `lib/bds/desktop/shell_live/chat_editor_html` | Same conversation loading, same input/send flow, same transcript rendering, same task/result presentation, same airplane-mode gating. |
| Misc maintenance editors | `src/renderer/components/SiteValidationView`, `TranslationValidationView`, `MetadataDiffPanel`, `DuplicatesView`, `GitDiffView` | `lib/bds/desktop/shell_live/misc_editor.ex`, `lib/bds/desktop/shell_live/misc_editor_html` | Same result summaries, same action buttons, same diff/repair/apply flows, same tab/filter behavior, same empty/error states. |

## Batch 3 Procedure

1. Freeze a parity row per slice: old file, new file, proof tests, manual scenario, current score, gap notes.
2. Run shell-level proof first: `mix test test/bds/desktop/shell_live_test.exs test/bds/ui/sidebar_test.exs`.
3. Audit shell chrome before individual editors, so layout/tabs/sidebar drift does not get misattributed to an editor.
4. Audit editors in this order: post, media, settings, style, tags, scripts, templates, chat, misc.
5. For each editor, capture only behavior deltas: missing flow, different state transition, styling drift, localization drift, or command wiring drift.
6. Mark each slice `green`, `yellow`, or `red`; do not down-score a row for a separate feature that is not implemented yet.

## Batch 3 Audit Snapshot

Current batch 3 parity scores for existing implemented UI/editor code only. Missing or not-yet-implemented surfaces are not counted as parity failures in this table.

| Slice | Score | Old bDS anchor | bDS2 anchor | Proof used | Existing-code parity result |
| --- | --- | --- | --- | --- | --- |
| Shell chrome | green | `src/renderer/components/ActivityBar`, `Sidebar`, `TabBar`, `Panel`, `WindowTitleBar`, `AssistantSidebar`, `App.tsx`, `App.css` | `lib/bds/desktop/shell_live.ex`, `lib/bds/desktop/shell_live/index.html.heex`, `lib/bds/ui/workbench.ex`, `lib/bds/desktop/shell_live/sidebar_components.ex`, `priv/ui/app.css` | `mix test test/bds/desktop/shell_live_test.exs test/bds/ui/sidebar_test.exs`; owner files and shell CSS compared | No material implemented-code parity drift found in the shell frame, activity/sidebar/tab/panel behavior, or current chrome styling. |
| Post editor | green | `src/renderer/components/Editor/PostEditor.tsx` | `lib/bds/desktop/shell_live/post_editor.ex`, `lib/bds/desktop/shell_live/post_editor_html/*` | `mix test test/bds/desktop/shell_live_test.exs`; post editor implementation compared | No material implemented-code parity drift found in the current save, publish, discard, preview, or published-body-loading flows. |
| Media editor | green | `src/renderer/components/Editor/MediaEditor.tsx` | `lib/bds/desktop/shell_live/media_editor.ex`, `lib/bds/desktop/shell_live/media_editor_html/*` | `mix test test/bds/desktop/shell_live_test.exs`; media editor implementation compared | No material implemented-code parity drift found in the current explicit-save, translation edit, linked-post, and metadata-edit flows. |
| Settings editor | green | `src/renderer/components/SettingsView/SettingsView.tsx` | `lib/bds/desktop/shell_live/settings_editor.ex`, `lib/bds/desktop/shell_live/settings_editor_html/settings_editor.html.heex` | `mix test test/bds/desktop/shell_live_test.exs`; settings editor implementation compared | No material implemented-code parity drift found in the current section model, AI settings groups, project/editor/content/publishing/data/MCP sections, or implemented search/filter behavior. |
| Style editor | green | `src/renderer/components/StyleView/StyleView.tsx` | `lib/bds/desktop/shell_live/settings_editor.ex`, `lib/bds/desktop/shell_live/settings_editor_html/style_editor.html.heex` | `mix test test/bds/desktop/shell_live_test.exs`; style editor implementation compared | No material implemented-code parity drift found in the current theme picker, preview mode, preview URL, and apply flow. |
| Tags editor | green | `src/renderer/components/TagsView/TagsView.tsx` | `lib/bds/desktop/shell_live/tags_editor.ex`, `lib/bds/desktop/shell_live/tags_editor_html/*` | `mix test test/bds/desktop/shell_live_test.exs`; tags editor implementation compared | No material implemented-code parity drift found in the current create/edit/delete/merge flows, color handling, or post-template selection behavior. |
| Script editor | green | `src/renderer/components/ScriptsView/ScriptsView.tsx` | `lib/bds/desktop/shell_live/code_entity_editor.ex`, `lib/bds/desktop/shell_live/code_entity_editor_html/script_editor.html.heex` | `mix test test/bds/desktop/shell_live_test.exs`; script editor implementation compared | No material implemented-code parity drift found in the current Monaco editor, metadata form, syntax check, run, save, delete, and entrypoint selection flow. |
| Template editor | green | `src/renderer/components/TemplatesView/TemplatesView.tsx` | `lib/bds/desktop/shell_live/code_entity_editor.ex`, `lib/bds/desktop/shell_live/code_entity_editor_html/template_editor.html.heex` | `mix test test/bds/desktop/shell_live_test.exs`; template editor implementation compared | No material implemented-code parity drift found in the current Monaco editor, metadata form, validate, save, and delete flow. |
| Chat editor | green | `src/renderer/components/ChatPanel/ChatPanel.tsx`, `src/renderer/components/ChatSurface/ChatTranscript.tsx` | `lib/bds/desktop/shell_live/chat_editor.ex`, `lib/bds/desktop/shell_live/chat_editor_html/chat_editor.html.heex`, `priv/ui/live.js` | `mix test test/bds/desktop/shell_live_test.exs`; chat editor implementation and hook flow compared | The current bDS2 chat route now matches the implemented old-panel surface for provider-grouped model selection, welcome state, persisted transcript, airplane-mode gating, API-key-required state, assistant markdown rendering, tool markers, structured tool surfaces, assistant navigation actions, Enter/Shift+Enter handling, auto-grow/auto-scroll, and in-flight stop/input-lock behavior. No further proven implemented-route drift remains in batch 3. |
| Misc maintenance editors | green | `src/renderer/components/SiteValidationView`, `TranslationValidationView`, `MetadataDiffPanel`, `DuplicatesView`, `GitDiffView` | `lib/bds/desktop/shell_live/misc_editor.ex`, `lib/bds/desktop/shell_live/misc_editor_html/misc_editor.html.heex` | `mix test test/bds/desktop/shell_live_test.exs`; misc editor implementation compared | No material implemented-code parity drift found in the current metadata diff, site validation, duplicate dismissal, translation validation, or working-tree git diff flows. Translation validation again uses dedicated issue cards with revalidate/fix actions, and git diff now uses the structured Monaco diff surface. |

## Batch 4 Audit Matrix

| Service slice | Old bDS anchor | bDS2 anchor | Audit questions |
| --- | --- | --- | --- |
| Projects and metadata | `src/main/engine/ProjectEngine.ts`, `MetaEngine.ts` | `lib/bds/projects.ex`, `lib/bds/metadata.ex` | Same project activation/switching semantics, same filesystem metadata sync, same category/theme/settings persistence, same defaults. |
| Rendering and preview | `src/main/engine/PageRenderer.ts`, `PreviewServer.ts`, `TemplateEngine.ts` | `lib/bds/rendering.ex`, `lib/bds/preview.ex`, `lib/bds/templates.ex` | Same template selection, same preview URL/content rules, same theme override behavior, same render-language behavior. |
| Generation and validation entry points | `src/main/engine/BlogGenerationEngine.ts`, `SiteValidationDiffService.ts` | `lib/bds/generation.ex`, `lib/bds/maintenance.ex` | Same command-surface semantics for generate/validate/apply where batch 3 editors trigger them, same result payload shapes, same update/apply behavior. |
| Publishing | `src/main/engine/PublishEngine.ts`, `PublishApiAdapter.ts` | `lib/bds/publishing.ex`, `lib/bds/desktop/shell_commands.ex` | Same queued-job behavior, same credential handling, same progress/result semantics, same UI entry points. |
| Tasks | `src/main/engine/TaskManager.ts` | `lib/bds/tasks.ex` | Same group/task lifecycle, same progress semantics, same status-bar/panel integration expectations. |
| Git | `src/main/engine/GitEngine.ts`, `GitApiAdapter.ts` | `lib/bds/git.ex`, `lib/bds/desktop/shell_live/misc_editor.ex` | Same repo state, same diff output expectations, same remote-state badge behavior, same editor integration. |
| Search | `src/main/engine/SearchIndexEngine.ts` | `lib/bds/search.ex` | Same reindex semantics, same content scope, same task/progress behavior, same downstream editor/search expectations. |
| Embeddings | `src/main/engine/EmbeddingEngine.ts` | `lib/bds/embeddings.ex` | Same rebuild/find-dismiss semantics, same duplicate pairing rules, same metadata-diff integration. |
| AI and model catalog | `src/main/engine/ChatEngine.ts`, `ModelCatalogEngine.ts`, `ai/*` | `lib/bds/ai.ex`, `lib/bds/ai/*` | Same endpoint/model resolution, same conversation/message behavior, same airplane-mode gating, same tool-call/UI expectations. |
| MCP | `src/main/engine/MCPServer.ts`, `mcp-view-builder.ts`, `mcp-views.ts` | `lib/bds/mcp.ex`, `lib/bds/mcp/*` | Same tool/resource coverage, same proposal/store behavior, same script/template bridge expectations. |
| CLI sync notification persistence | `src/main/engine/NotificationWatcher.ts` | `lib/bds/cli_sync.ex` | For the implemented notification store/drain/prune logic, do the `db_notifications` semantics match the old app. |

## Batch 4 Procedure

1. Freeze a parity row per service slice: old engine, bDS2 module, proof tests, owning editor/shell entry point, current score, gap notes.
2. Run the current proof set in four groups.
3. Group A: `mix test test/bds/generation_test.exs test/bds/maintenance_test.exs test/bds/rendering_test.exs test/bds/preview_test.exs`.
4. Group B: `mix test test/bds/posts_test.exs test/bds/media_test.exs test/bds/tags_test.exs test/bds/templates_test.exs test/bds/scripts_test.exs test/bds/projects_test.exs`.
5. Group C: `mix test test/bds/publishing_test.exs test/bds/git_test.exs test/bds/search_test.exs test/bds/embeddings_test.exs test/bds/desktop/shell_commands_test.exs`.
6. Group D: `mix test test/bds/ai_test.exs test/bds/mcp_server_test.exs test/bds/mcp_test.exs`.
7. Supplemental direct proofs for slices not fully covered by the grouped runs: `mix test test/bds/metadata_test.exs`, `mix test test/bds/tasks_test.exs`, and `mix test test/bds/cli_sync_test.exs`.
8. After the proof set, probe each service through the matching shell/editor action when that entry point already exists and is part of the implemented surface being scored.
9. Mark each slice `green`, `yellow`, or `red`; do not down-score a row for a separate feature that is not implemented yet.

## Batch 4 Audit Snapshot

Current batch 4 parity scores for implemented backend code only. This snapshot is the output of completed step 6. Missing or not-yet-implemented surfaces are not counted as parity failures in this table.

| Service slice | Score | Old bDS anchor | bDS2 anchor | Owning shell/editor entry | Proof used | Existing-code parity result |
| --- | --- | --- | --- | --- | --- | --- |
| Projects and metadata | green | `src/main/engine/ProjectEngine.ts`, `src/main/engine/MetaEngine.ts` | `lib/bds/projects.ex`, `lib/bds/metadata.ex` | `lib/bds/desktop/shell_live.ex`, `lib/bds/desktop/shell_live/settings_editor.ex` | `mix test test/bds/projects_test.exs`, `mix test test/bds/metadata_test.exs`; existing shell-live settings/project-switcher coverage reviewed | No material backend parity drift found in the current pass. |
| Rendering and preview | green | `src/main/engine/PageRenderer.ts`, `src/main/engine/PreviewServer.ts`, `src/main/engine/TemplateEngine.ts` | `lib/bds/rendering.ex`, `lib/bds/preview.ex`, `lib/bds/templates.ex` | `lib/bds/desktop/shell_live/post_editor.ex`, `lib/bds/desktop/shell_live/settings_editor.ex` | `mix test test/bds/rendering_test.exs test/bds/preview_test.exs`; existing shell-live preview/style coverage reviewed | No material backend parity drift found in the current pass. |
| Generation and validation entry points | green | `src/main/engine/BlogGenerationEngine.ts`, `src/main/engine/SiteValidationDiffService.ts` | `lib/bds/generation.ex`, `lib/bds/maintenance.ex` | `lib/bds/desktop/shell_commands.ex`, `lib/bds/desktop/shell_live/misc_editor.ex` | `mix test test/bds/generation_test.exs test/bds/maintenance_test.exs`, `mix test test/bds/desktop/shell_commands_test.exs` | No material backend parity drift found in the current pass. |
| Publishing | green | `src/main/engine/PublishEngine.ts`, `src/main/engine/PublishApiAdapter.ts` | `lib/bds/publishing.ex`, `lib/bds/desktop/shell_commands.ex` | Publishing section under `lib/bds/desktop/shell_live/settings_editor.ex` | `mix test test/bds/publishing_test.exs`; shell ownership reviewed | The implemented queued-job, credential, scp/rsync, sidecar-filter, and persistence behavior matches the old engine surface closely enough for green. |
| Tasks | green | `src/main/engine/TaskManager.ts` | `lib/bds/tasks.ex` | `lib/bds/desktop/shell_live.ex`, `lib/bds/ui/workbench.ex` | `mix test test/bds/tasks_test.exs`, `mix test test/bds/desktop/shell_commands_test.exs`; existing shell task-panel/status coverage reviewed | No material backend parity drift found in the current pass. |
| Git | green | `src/main/engine/GitEngine.ts`, `src/main/engine/GitApiAdapter.ts` | `lib/bds/git.ex`, `lib/bds/desktop/shell_live/misc_editor.ex` | Legacy git activity badge plus misc git-diff surface in `lib/bds/desktop/shell_live.ex` | `mix test test/bds/git_test.exs`; existing shell-live remote-badge coverage reviewed | The implemented repository, status, diff, history, remote-state, and fetch/pull/push semantics are close enough to old bDS for green on existing backend code. |
| Search | green | `src/main/engine/SearchIndexEngine.ts` | `lib/bds/search.ex` | `lib/bds/desktop/shell_commands.ex` via `reindex_text` | `mix test test/bds/search_test.exs`, `mix test test/bds/desktop/shell_commands_test.exs` | No material backend parity drift found in the current pass. |
| Embeddings | green | `src/main/engine/EmbeddingEngine.ts` | `lib/bds/embeddings.ex` | `lib/bds/desktop/shell_commands.ex`, `lib/bds/desktop/shell_live/misc_editor.ex` | `mix test test/bds/embeddings_test.exs`, `mix test test/bds/desktop/shell_commands_test.exs`; existing metadata-diff/duplicates shell coverage reviewed | No material backend parity drift found in the current pass. |
| AI and model catalog | green | `src/main/engine/ChatEngine.ts`, `src/main/engine/ModelCatalogEngine.ts`, `src/main/engine/ai/*` | `lib/bds/ai.ex`, `lib/bds/ai/*` | `lib/bds/desktop/shell_live/chat_editor.ex`, `lib/bds/desktop/shell_live/settings_editor.ex` | `mix test test/bds/ai_test.exs`; existing shell-live AI-settings/chat coverage reviewed | No material backend parity drift found for the implemented AI and catalog flows. |
| MCP | green | `src/main/engine/MCPServer.ts`, `src/main/engine/mcp-view-builder.ts`, `src/main/engine/mcp-views.ts` | `lib/bds/mcp.ex`, `lib/bds/mcp/server.ex`, `lib/bds/mcp/*` | MCP section under `lib/bds/desktop/shell_live/settings_editor.ex` and external MCP transport | `mix test test/bds/mcp_server_test.exs test/bds/mcp_test.exs` | No material backend parity drift found for the implemented tool, resource, proposal, and server surface. |
| CLI sync notification persistence | green | `src/main/engine/NotificationWatcher.ts` | `lib/bds/cli_sync.ex` | Notification rows consumed outside the shell; no desktop watcher is scored here | `mix test test/bds/cli_sync_test.exs` | The implemented `db_notifications` insert, drain, seen-marking, and prune semantics match the old row-handling behavior. Desktop watch/invalidation is outside this existing-code score because it is not implemented in bDS2. |

## Audit Outputs Required

1. A single parity matrix covering every batch 3 and batch 4 slice.
2. A green/yellow/red score per slice, never just narrative confidence.
3. The exact old file and exact bDS2 file that own each behavior.
4. The proof command or manual scenario used for the score.
5. A minimal change backlog containing only proven drifts in batch 3 and batch 4.

## Unresolved Questions

None.
