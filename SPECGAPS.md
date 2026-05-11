# Spec Gaps — Allium Specs vs Code vs Tests

Gap categories: **SC** = spec correct, fix code | **CS** = code correct, update spec | **ST** = write test | **SD** = decide | **SI** = fix internal spec inconsistency

---

## A. Spec Claims Not Fulfilled by Code

### A1. Code Must Change (spec is normative)

| ID | Gap | Spec | Code | Path |
|---|---|---|---|---|
| A1-1 | No `archived→draft` or `archived→published` transition | post.allium:121-122 | No code path to unarchive | Fix code or spec-restrict transitions |
| A1-2 | `DeletePost` must delete translations + translation files | post.allium:209-212 | `delete_post/1` skips translation cleanup | Fix code: delete PostTranslation rows + files |
| A1-3 | Publish must delete old file when path changes | engine_side_effects.allium:73-74 | `publish_post` does not delete old file | Fix code: add old file deletion on path change |
| A1-4 | `doNotTranslate: false` written to frontmatter despite "only when true" | frontmatter.allium:398 | `lib/bds/frontmatter.ex:38-39` writes false | Fix code: omit `doNotTranslate` when false |

### A2. Spec Should Update (code is normative)

| ID | Gap | Spec | Code | Path |
|---|---|---|---|---|
| A2-1 | WYSIWYG/visual editor mode (3 modes) | editor_post.allium:159-164 | Only markdown+preview; visual normalizes to markdown | Drop from spec or mark future |
| A2-2 | Auto-save after 3000ms idle | editor_post.allium:183-188 | No auto-save timer | Drop from spec or mark future |
| A2-3 | On-demand rendering in preview | preview.allium:53-93 | Static file serving from generated output | Update spec: preview serves pre-generated files |
| A2-4 | Template/Script are global entities | template.allium, script.allium | Both have `project_id`, per-project uniqueness | Update spec to per-project scoping |
| A2-5 | TagsFile uses `{tags: [...]}` wrapper | frontmatter.allium:255-273 | Code writes bare array `[...]` | Update spec |
| A2-6 | Sidecar is "YAML-like, not gray-matter" | frontmatter.allium:174 | Code wraps with `---` delimiters | Update spec to gray-matter style |
| A2-7 | Translation frontmatter omits status/timestamps | frontmatter.allium:107-117 | Code writes status, createdAt, updatedAt, publishedAt | Update spec to match written fields |
| A2-8 | Search index has single `stemmed_content` | search.allium:40-54 | FTS5 per-field stemmed columns | Update spec to per-field model |
| A2-9 | Tag archives are single-page | generation.allium:142-147 | Code paginates | Update spec |
| A2-10 | Date archives year+month only | generation.allium:151-159 | Code also generates day-level | Update spec |
| A2-11 | Menu is DB entity | menu.allium:20-26 | Purely file-based OPML, no DB table | Update spec to file-only model |
| A2-12 | Panel tabs: problems, terminal | layout.allium:235-240 | `[:tasks, :output, :post_links, :git_log]` | Update spec |
| A2-13 | Template lookup 4 levels (post→tag→category→default) | template_context.allium:267-277 | Only levels 1 and 4 implemented | Drop levels 2-3 or implement |
| A2-14 | `ValidateLiquid`/`ValidateScript` before publish | template.allium:110, script.allium:165 | No validation gate before publish | Add to code or drop from spec |
| A2-15 | Graceful shutdown with inflight tracking | preview.allium:47-48 | Kills acceptor, no inflight tracking | Drop from spec |
| A2-16 | Pagefind as real library | generation.allium:208 | Simplified JSON-based mock | Update spec to mock model |
| A2-17 | 24 Snowball stemmers all with algorithms | search.allium:26-31 | Only 15/24 have algorithms; 9 pass through unstemmed | Update spec: 15 stemmed + 9 passthrough |
| A2-18 | Git sidebar: commit input, history, push/pull | sidebar_views.allium | Only "Working tree" item | Mark as partial/TODO in spec |
| A2-19 | 17 preset colors in tag picker | editor_tags.allium | Native `<input type="color">`, no preset palette | Update spec |
| A2-20 | Slug timestamp fallback after 999 | post.allium:21 | Unbounded numeric suffix | Update spec or fix code |
| A2-21 | Thumbnail generation is async | engine_side_effects.allium:117 | Synchronous | Update spec or fix code |

### A3. Decisions Needed

| ID | Gap | Spec | Code | Path |
|---|---|---|---|---|
| A3-1 | Template file written on create | engine_side_effects.allium:151-153 | Draft templates have `file_path=""` | Decide: write file on create, or update spec |
| A3-2 | `provider_package_ref` on AiModel | schema.allium:282 | Not in code | Decide: add field or drop from spec |
| A3-3 | AiModelModality: :video vs :file/:tool | schema.allium:291 | Code has `:file`, `:tool` instead of `:video` | Decide: which modalities are correct |
| A3-4 | JSON key convention: snake_case vs camelCase | frontmatter.allium values | Code uses camelCase for all metadata JSON | Decide normative convention |

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
| B1-8 | `linkedPostIds` in media sidecar | `lib/bds/media/sidecars.ex:42` | Add to frontmatter.allium MediaSidecar |
| B1-9 | `projectId` in template/script frontmatter | `templates.ex:337`, `scripts.ex:268` | Add to frontmatter.allium |
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

| ID | Conflict | Location | Path |
|---|---|---|---|
| C-1 | schema.allium ChatMessage has no cache tokens; ai.allium ChatMessage has `cache_read_tokens`/`cache_write_tokens` | schema.allium:235-243 vs ai.allium:147-156 | Align schema.allium with ai.allium (code matches ai.allium) |
| C-2 | media.allium SidecarFile mentions `linkedPostIds`; frontmatter.allium MediaSidecar does NOT list it | media.allium:28 vs frontmatter.allium:171-190 | Add `linkedPostIds` to frontmatter.allium |
| C-3 | translation.allium says status/timestamps omitted from translation files; frontmatter.allium TranslationFrontmatter defines only 5 fields; code writes 8+ fields | translation.allium:67-74, frontmatter.allium:107-117 | Reconcile: either update spec or fix code |

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

1. **A1-1 through A1-4** — code bugs (spec is correct)
2. **D1-1 through D1-18** — untested invariants/guarantees
3. **C-1 through C-3** — internal spec inconsistencies
4. **B1-1 through B1-6** — major code behaviors missing from spec
5. **A2-1 through A2-21** — spec drift (code is normative)
6. **D2-1 through D2-17** — untested rules
7. **D3-1 through D3-11** — partial test coverage
8. **B1-7 through B1-20** — minor code behaviors missing from spec
9. **D4-1 through D4-7** — UI test coverage
10. **A3-1 through A3-4** — decisions needed
