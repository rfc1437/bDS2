# Spec Gaps — Allium Specs vs Code vs Tests

Gap categories: **SC** = spec correct, fix code | **CS** = code correct, update spec | **ST** = write test | **SD** = decide | **SI** = fix internal spec inconsistency

---

## A. Spec Claims Not Fulfilled by Code

### A1. Code Must Change (spec is normative)

| ID | Gap | Spec | Code | Path |
|---|---|---|---|---|
| A1-1 | ~~No `archived→draft` or `archived→published` transition~~ | post.allium:121-122 | `unarchive_post/1` implemented, `publish_post` already handled archived→published | **Resolved:** `unarchive_post/1` in posts.ex restores content from disk, UI wired via quick actions, 4 tests added |
| A1-2 | ~~`DeletePost` must delete translations + translation files~~ | post.allium:209-212 | `delete_post/1` now fetches translations before cascade-delete and removes their files from disk | **Resolved:** translation file cleanup added to `delete_post/1` in posts.ex, test added |
| A1-3 | ~~Publish must delete old file when path changes~~ | engine_side_effects.allium:73-74 | `publish_post` now deletes old file when `file_path` changes | **Resolved:** old file deletion added to `publish_post/1` in posts.ex, test added |
| A1-4 | ~~`doNotTranslate: false` written to frontmatter despite "only when true"~~ | frontmatter.allium:398 | `file_sync.ex:78` now converts false→nil so serializer omits the key | **Resolved:** doNotTranslate omitted from frontmatter when false, test added |
| A1-5 | ~~Auto-save after 3000ms idle~~ | editor_post.allium:183-188 | PostEditor schedules auto-save via parent timer on dirty change | **Resolved:** 3000ms idle auto-save timer in Bridges, tab-switch save in ShellLive, cancel on manual save, 3 tests added |
| A1-6 | ~~On-demand rendering in preview server~~ | preview.allium:53-93 | `Preview.Router` matches post/archive/home/language routes and renders on-demand via `Rendering` | **Resolved:** `Preview.Router` implements on-demand template rendering for post, archive, home, date, tag, category, page, and language-prefixed routes; static file fallback retained for non-HTML assets (pagefind, feeds); 6 tests added |
| A1-7 | ~~Template lookup must use all 4 levels (post→tag→category→default)~~ | template_context.allium:267-277 | `resolve_post_template_slug/3` implements tag→category cascade; all callers (preview, generation) updated | **Resolved:** `resolve_post_template_slug/3` in template_selection.ex, callers in preview.ex, router.ex, outputs.ex updated, 8 tests added |
| A1-8 | ~~`ValidateLiquid`/`ValidateScript` before publish~~ | template.allium:110, script.allium:165 | `publish_template` validates Liquid via `Liquex.parse`, `publish_script` validates Lua via `BDS.Scripting.validate` | **Resolved:** validation gates added to `publish_template/1` and `publish_script/1`, invalid content returns `{:error, {:invalid_liquid|:invalid_script, reason}}`, 4 tests added |
| A1-9 | 17 preset colors + custom hex in tag picker | editor_tags.allium | Native `<input type="color">`, no preset palette | Fix code: implement preset color palette popover |
| A1-10 | Template file written on create | engine_side_effects.allium:151-153 | Draft templates have `file_path=""` | Fix code: write template file on create |
| A1-11 | Graceful shutdown with inflight request tracking | preview.allium:47-48 | Kills acceptor process, no inflight tracking | Fix code: track inflight requests, drain before shutdown |
| A1-12 | Real Pagefind integration for search | generation.allium:208 | Stub only: `pagefind-ui.js` is one-liner, `PagefindUI` never defined, search-runtime.js silently bails, client-side search non-functional | Fix code: bundle real Pagefind, build proper fragment index, wire PagefindUI |
| A1-13 | Git sidebar shows only "Working tree" placeholder | sidebar_views.allium:651-770 | `sidebar.ex:782-798` returns single entity_list item; `BDS.Git` has full status/diff/commit/history/fetch/pull/push/prune_lfs but sidebar doesn't use it | Fix code: wire sidebar `git_view/0` to `BDS.Git` — render branch, ahead/behind, status file list, commit input, history entries, action buttons per spec |
| A1-14 | Embedding uses TF-IDF hash projection instead of real neural model | embedding.allium:44-53, invariants ModelCaching/VectorCacheInDb | `backends/in_app.ex` hashes terms into sparse vectors via `:erlang.phash2`; no ONNX model, no `"query: "` prefix, no mean pooling, vectors stored as JSON text not Float32Array BLOB, snapshot-based neighbor lookup instead of USearch HNSW index | Fix code: (1) add Bumblebee + ONNX runtime deps to run `Xenova/multilingual-e5-small`, (2) implement lazy model download + cache in app data dir, (3) `"query: "` prefix + mean pooling + L2 norm in backend, (4) store vectors as binary BLOB (1536 bytes), (5) replace JSON snapshot with USearch HNSW index (cosine, M=16, ef=128/64, 5s debounce), (6) cross-language semantic similarity must work |
| A1-15 | ~~Preview vs generation content source strategy undocumented~~ | preview.allium (no invariant), generation.allium (no invariant) | Generation uses only published .md file content (`Generation.Data` snapshots set `content: nil`); preview includes published+draft posts and prefers DB content over file (`Preview.Router` queries `:published`/`:draft`, uses `editor_body`) | **Resolved:** added `PreviewDraftOverlay` invariant to preview.allium and `GenerationPublishedOnly` invariant to generation.allium; both cross-reference each other; code already correct, 3 tests added for draft-in-preview behavior |

### A2. Spec Should Update (code is normative)

| ID | Gap | Spec | Code | Path |
|---|---|---|---|---|
| A2-1 | ~~WYSIWYG/visual editor mode (3 modes)~~ | editor_post.allium:159-164 | Only markdown+preview; visual normalizes to markdown | **Resolved:** spec updated to 2 modes (markdown/preview), visual/WYSIWYG dropped |
| A2-2 | ~~Template/Script are global entities~~ | template.allium, script.allium | Both have `project_id`, per-project uniqueness | **Resolved:** spec updated — added `project_id` to entities, scoped uniqueness invariants and create rules per project |
| A2-3 | ~~TagsFile uses `{tags: [...]}` wrapper~~ | frontmatter.allium:255-273 | Code writes bare array `[...]` | **Resolved:** spec updated — removed wrapper object, TagEntry is now the top-level value, bare array in invariant, camelCase keys |
| A2-4 | ~~Sidecar is "YAML-like, not gray-matter"~~ | frontmatter.allium:174 | Code wraps with `---` delimiters | **Resolved:** spec updated — format comment now says gray-matter style with --- delimiters |
| A2-5 | ~~Translation frontmatter omits status/timestamps~~ | frontmatter.allium:107-117 | Code writes status, createdAt, updatedAt, publishedAt | **Resolved:** spec updated — TranslationFrontmatter now includes status, created_at, updated_at, published_at; TranslationFilesInheritCanonicalMetadata renamed to TranslationFrontmatterRoundtrip; translation.allium invariant updated to TranslationFilesCarryFullMetadata |
| A2-6 | ~~Search index has single `stemmed_content`~~ | search.allium:40-54 | FTS5 per-field stemmed columns | **Resolved:** spec updated — PostSearchIndex has title/excerpt/content/tags/categories; MediaSearchIndex has title/alt/caption/original_name/tags; SearchMedia now accepts filters; index rules use delete-and-reinsert with per-field stemming |
| A2-7 | ~~Tag archives are single-page~~ | generation.allium:142-147 | Code paginates | **Resolved:** spec updated — GenerateTagPages now paginated like categories, using max_posts_per_page |
| A2-8 | ~~Date archives year+month only~~ | generation.allium:151-159 | Code also generates day-level | **Resolved:** spec updated — GenerateDateArchivePages now includes day-level archives, all three levels paginated |
| A2-9 | ~~Menu is DB entity~~ | menu.allium:20-26 | Purely file-based OPML, no DB table | **Resolved:** spec updated — `entity Menu` changed to `value Menu`, file-only model with OPML persistence, added LoadMenu/SyncMenuFromFilesystem rules |
| A2-10 | ~~Panel tabs: problems, terminal~~ | layout.allium:235-240 | `[:tasks, :output, :post_links, :git_log]` | **Resolved:** spec already lists tasks/output/post_links/git_log with availability and fallback rules matching code |
| A2-11 | ~~Git sidebar: commit input, history, push/pull~~ | sidebar_views.allium | Only "Working tree" item | **Moved to A1-13:** backend code exists in BDS.Git, sidebar must wire it up |
| A2-12 | ~~Slug timestamp fallback after 999~~ | post.allium:21 | Unbounded numeric suffix | **Resolved:** spec updated — uniqueness comment now says unbounded numeric suffix, no 999 cap or timestamp fallback |
| A2-13 | ~~Thumbnail generation is async~~ | engine_side_effects.allium:117 | Synchronous | **Resolved:** spec updated — import thumbnail generation now says synchronous (awaited, logged on error), matching code; summary table changed from `async` to `sync` |
| A2-14 | ~~AiModelModality: :video vs :file/:tool~~ | schema.allium:291 | Code has `:file`, `:tool` instead of `:video` | **Resolved:** spec updated — modality enum now lists "text" \| "image" \| "audio" \| "file" \| "tool", matching code |
| A2-15 | ~~JSON key convention: snake_case vs camelCase~~ | frontmatter.allium values | Code uses camelCase for all metadata JSON | **Resolved:** all value types in frontmatter.allium updated to camelCase field names; added CamelCaseKeys invariant; surfaces updated; also added linkedPostIds to MediaSidecar (C-2) and projectId to TemplateFrontmatter/ScriptFrontmatter (B1-9) |
| A2-16 | ~~Snowball stemmer language list~~ | search.allium:26-31 | Library determines which have algorithms vs passthrough | **Resolved:** spec updated — StemmerLanguage comment now says "Snowball stemmers via library (Stemex); languages with algorithm get real stemming, others pass through" |
| A2-17 | ~~`provider_package_ref` on AiModel~~ | schema.allium:282 | Not in code; legacy field not needed | **Resolved:** dropped from AiModel entity and AiModelRecordSurface in schema.allium; DB column retained (migration artifact) |

---

## B. Code Behavior Not in Spec

### B1. Must Add to Spec (domain-level, affects behavior)

| ID | Behavior | Code Location | Path |
|---|---|---|---|
| B1-1 | Chat inline surfaces (9 types: card, chart, form, list, metric, mindmap, table, tabs, text/json) | `lib/bds/ui/chat/tool_surfaces.ex:6-15` | Distill into spec |
| B1-2 | Auto-translation system (AutoTranslation.maybe_schedule, media cascade, batch fill) | `lib/bds/posts/auto_translation.ex` | Distill into spec |
| B1-3 | 3 extra settings sections (Technology, MCP, Data Maintenance) | `lib/bds/ui/settings_editor/` | Distill into spec |
| B1-4 | Style/Theme as separate tab (`:style`), not settings section | `lib/bds/ui/style_editor.ex` | Distill into spec |
| B1-5 | `published_*` snapshot fields on Post for diffing | `lib/bds/posts/post.ex:61-65` | Add to post.allium entity |
| B1-6 | Full rendering subsystem (Liquex, Filters, Labels, LinksAndLanguages, PostRendering) | `lib/bds/rendering/` | Distill into spec |
| B1-7 | 404.html generation | `lib/bds/generation/outputs.ex:344-345` | Add to generation.allium |
| B1-8 | ~~`linkedPostIds` in media sidecar~~ | `lib/bds/media/sidecars.ex:42` | **Resolved:** added to MediaSidecar value in frontmatter.allium (with A2-15) |
| B1-9 | ~~`projectId` in template/script frontmatter~~ | `templates.ex:337`, `scripts.ex:268` | **Resolved:** added projectId to TemplateFrontmatter and ScriptFrontmatter in frontmatter.allium (with A2-15) |
| B1-10 | Media translation editing modal | `media_editor.html.heex:275-303` | Add to editor_media.allium |
| B1-11 | Menu editor drag-drop, indent/unindent/move | `lib/bds/desktop/menu_editor/tree_ops.ex` | Add to editor_misc.allium |
| B1-12 | `:language_picker` overlay with flag emojis | `shell_overlay.html.heex:116-139` | Add to modals.allium |
| B1-13 | `:confirm_dialog` generic confirmation | `shell_overlay.html.heex:171-187` | Add to modals.allium |
| B1-14 | Publish actions for scripts and templates | `script_editor.html.heex:10-12`, `template_editor.html.heex:10-12` | Add to editor_script.allium, editor_template.allium |
| B1-15 | `:import` as full editor tab | `lib/bds/ui/import_editor.ex` | Add to tabs.allium |
| B1-16 | `:documentation`/`:api_documentation` tab types | `lib/bds/desktop/misc_editor/` | Add to tabs.allium |
| B1-17 | Metadata diff covers embedding, media_translation, post_translation as entity types | `lib/bds/maintenance/repair.ex` | Add to metadata_diff.allium |
| B1-18 | Finished task TTL eviction (1h, keep last 10) | `lib/bds/tasks.ex:365-386` | Add to task.allium |
| B1-19 | `discard_post_changes/1` | `lib/bds/posts.ex:201-227` | Add to post.allium |
| B1-20 | `replace_media_file/2` with checksum/backup | `lib/bds/media.ex:288-337` | Add to media.allium |

### B2. Lower Priority (implementation detail or minor)

| ID | Behavior | Code Location |
|---|---|---|
| B2-1 | `editor_body/1` content resolver | `lib/bds/posts.ex:229-252` |
| B2-2 | `sync_post_from_file/1` single-post reimport | `lib/bds/posts.ex:254-279` |
| B2-3 | `import_orphan_post_file/1` | `lib/bds/posts.ex:289-291` |
| B2-4 | `dashboard_stats/1`, `post_counts_by_year_month/1` | `lib/bds/posts.ex:378-413` |
| B2-5 | `regenerate_missing_thumbnails/2` | `lib/bds/media.ex:47-48` |
| B2-6 | Cache dir computation | `lib/bds/projects.ex:101-106` |
| B2-7 | `remove_stale_published_templates` | `lib/bds/templates.ex:524-552` |
| B2-8 | Rendering Labels module (30+ i18n strings) | `lib/bds/rendering/labels.ex` |
| B2-9 | Progress reporting during reindex | `lib/bds/generation/progress.ex` |

---

## C. Internal Spec Inconsistencies

All reconciled to follow code. Specs must be self-consistent and match code.

| ID | Conflict | Resolution | Path |
|---|---|---|---|
| C-1 | schema.allium ChatMessage has no cache tokens; ai.allium ChatMessage has `cache_read_tokens`/`cache_write_tokens` | Code has cache tokens → align schema.allium with ai.allium | Update schema.allium |
| C-2 | ~~media.allium SidecarFile mentions `linkedPostIds`; frontmatter.allium MediaSidecar does NOT list it~~ | Code writes `linkedPostIds` → add to frontmatter.allium | **Resolved:** linkedPostIds added to MediaSidecar in frontmatter.allium (with A2-15) |
| C-3 | ~~translation.allium says status/timestamps omitted; frontmatter.allium TranslationFrontmatter defines only 5 fields; code writes 8+ fields~~ | Code writes status/timestamps → update both specs to match code | **Resolved:** both specs updated (see A2-5) |

---

## D. Spec Claims Not Covered by Tests

### D1. No Test Coverage (HIGH priority — invariants/guarantees)

| ID | Claim | Spec | Path |
|---|---|---|---|
| D1-1 | UniqueMediaTranslation invariant | media.allium:108 | Write test: create duplicate media translation, expect rejection |
| D1-2 | UniqueTranslationPerLanguage invariant | translation.allium:94 | Write test: create duplicate post translation, expect rejection |
| D1-3 | BundledDefaultTemplatesExistOutsideProjectData | template.allium:65 | Write test: render with no Template rows, bundled template found |
| D1-4 | UserTemplateDirectoryOverridesBundledDefaults | template.allium:75 | Write test: project template overrides bundled same-slug |
| D1-5 | LiquidTagSubset (5 tags only) | template.allium:179 | Write test: unsupported tag raises error |
| D1-6 | LiquidFilterSubset (4 standard + 2 custom) | template.allium:191 | Write test: unsupported filter raises error |
| D1-7 | LiquidOperatorSubset | template.allium:210 | Write test: unsupported operator raises error |
| D1-8 | MacroTimeout guarantee | script.allium:94-95 | Write test: macro times out within budget |
| D1-9 | ExecuteTransform rule (pipeline, ordering, toast budget) | script.allium:229-263 | Write test: transform pipeline executes in order, toast budget enforced |
| D1-10 | TransformPipelineContinuation | script.allium:247-249 | Write test: error in transform doesn't halt pipeline |
| D1-11 | ChatContextTruncation invariant | ai.allium:375-379 | Write test: long chat history trimmed to context window |
| D1-12 | BoundedToolLoop enforcement | ai.allium:381-385 | Write test: tool rounds bounded by chat_max_tool_rounds |
| D1-13 | DiscardPostChangesSideEffects | engine_side_effects.allium:99-104 | Write test: FTS updated after discard |
| D1-14 | ReplaceMediaFileSideEffects | engine_side_effects.allium:128-134 | Write test: file replaced, thumbnails regenerated |
| D1-15 | Drag-and-drop image chain | action_patterns.allium:84-103 | Write integration test |
| D1-16 | DebouncedPersistence (5s) | embedding.allium:204-208 | Write test: index persistence debounced |
| D1-17 | Protected categories cannot be deleted | editor_settings.allium:81-84 | Write test: article/aside/page/picture deletion rejected |
| D1-18 | HomeItemProtection (menu) | editor_misc.allium:206-209 | Write test: cannot move/reorder/delete Home |

### D2. No Test Coverage (MEDIUM priority — rules/behaviors)

| ID | Claim | Spec | Path |
|---|---|---|---|
| D2-1 | RemoveCategory rule | metadata.allium:100 | Write test: remove category, verify list+settings+JSON updated |
| D2-2 | CreateAndPublishTemplate rule | template.allium:105 | Write test: create+publish in one step |
| D2-3 | CreateAndPublishScript rule | script.allium:160 | Write test: create+publish in one step |
| D2-4 | UniqueScriptSlug dedup | script.allium:115 | Write test: two scripts same title → dedup slug |
| D2-5 | FrontmatterRoundtrip invariant | post.allium:223 | Write test: write file, read back, assert all DB fields match |
| D2-6 | SidecarRoundtrip invariant | media.allium:198 | Write test: write sidecar, read back, assert all fields match |
| D2-7 | ConditionalPostFields: nil fields absent from frontmatter | frontmatter.allium:398 | Write test: post with nil excerpt/author/language → fields not in file |
| D2-8 | ConditionalMediaFields: nil fields absent from sidecar | frontmatter.allium:417 | Write test: media with nil title/alt → fields not in sidecar |
| D2-9 | max_posts_per_page 1..500 constraint | metadata.allium:75-77 | Write test: values outside range rejected |
| D2-10 | SandboxedExecution: restricted capabilities blocked | script.allium:84-88 | Write test: filesystem/process/package loading blocked |
| D2-11 | TransformToastBudget enforcement | script.allium:251-258 | Write test: per-script and total toast limits enforced |
| D2-12 | ProgressThrottled: 250ms throttle | task.allium:110-113 | Write test: rapid progress reports throttled |
| D2-13 | archived→draft transition | post.allium:121 | Write test: unarchive post → draft |
| D2-14 | archived→published transition | post.allium:122 | Write test: unarchive post → published |
| D2-15 | AppNoopNotifier: app writes don't produce notification rows | cli_sync.allium:64-68 | Write test: app mutation produces no notification row |
| D2-16 | ValidateMedia rule | media_processing.allium:318-343 | Write test: missing/corrupted/orphan media detected |
| D2-17 | ContentHashSkipsUnchanged during reindex | embedding.allium:199-202 | Write test: unchanged content_hash skips re-embedding |

### D3. Partial Test Coverage (needs expansion)

| ID | Claim | Spec | Gap | Path |
|---|---|---|---|---|
| D3-1 | PublishPost: content=null after publish | post.allium:186 | Not explicitly tested | Add assertion |
| D3-2 | PublishPost: old file deleted on path change | engine_side_effects.allium:73-74 | Not tested | Add test |
| D3-3 | UpsertPostTranslation: do_not_translate guard | translation.allium:113 | Indirectly covered only | Add direct test |
| D3-4 | PublishTemplate: Liquid validation prerequisite | template.allium:139 | Not tested as publish gate | Add test |
| D3-5 | PublishScript: validation prerequisite | script.allium:181 | Not tested as publish gate | Add test |
| D3-6 | ExecuteMacro failure degrades to empty | script.allium:199 | Returns error tuple, not empty | Fix code or update spec |
| D3-7 | TemplateFrontmatter roundtrip | template.allium:53 | Slug verified, no full parse-back | Add roundtrip test |
| D3-8 | DefaultCategories for fresh project | metadata.allium:60 | Defaults present after add, not verified fresh | Add fresh-project test |
| D3-9 | FtsIncludesTranslations | translation.allium:178 | Tested for one language; expand | Test all stemmer languages |
| D3-10 | PostCanonicalUrl format | post.allium:33-40 | Constructed in links test, not asserted as invariant | Add format assertion |
| D3-11 | Slug generation: German transliteration | post.allium:14-22 | "Föö Bär" → "foo-bar-blog" tested; expand ä/ö/ü/ß/ÄÖÜ | Expand test |

### D4. UI Test Coverage Gaps (whole-editor specs)

| ID | Spec | Covered | Not Covered |
|---|---|---|---|
| D4-1 | editor_media.allium | AI analysis, delete | Translate, replace file, link-to-post, translation CRUD, detect language |
| D4-2 | editor_settings.allium | AI endpoints, airplane toggle, rebuild | Protected categories, MCP agents, style/theme, search filter, categories CRUD |
| D4-3 | editor_chat.allium | Chat creation, pinned tab | API key screen, message rendering, input area, model selector, inline surfaces |
| D4-4 | editor_script.allium | Editor layout, create defaults | Save, syntax check, run, delete |
| D4-5 | editor_template.allium | Editor layout, create defaults | Save with validation, validate, delete with references |
| D4-6 | editor_tags.allium | Sync/discover, merge | Cloud sizing, color picker, delete confirmation, create form |
| D4-7 | editor_misc.allium | Menu add/save, metadata diff, validation | Menu protection, import analysis, translation fix, duplicate dismiss, git diff |

---

## Priority Order for Resolution

1. **A1-1 through A1-14** — code must follow spec (includes auto-save, on-demand preview, template lookup, validation gates, real Pagefind, graceful shutdown, real embedding model)
2. **D1-1 through D1-18** — untested invariants/guarantees
3. **C-1 through C-3** — internal spec inconsistencies (reconcile to code)
4. **B1-1 through B1-6** — major code behaviors missing from spec
5. **A2-1 through A2-17** — spec drift (code is normative, update spec)
6. **D2-1 through D2-17** — untested rules
7. **D3-1 through D3-11** — partial test coverage
8. **B1-7 through B1-20** — minor code behaviors missing from spec
9. **D4-1 through D4-7** — UI test coverage
