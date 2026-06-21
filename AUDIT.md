# Ponytail Audit: bDS2 Codebase

Scope: over-engineering, dead code, hand-rolled stdlib, yagni. Out of scope: correctness,
security, performance.

Estimated reduction: ~2,100 lines deleted, 0 deps removed.

**Rules:** One public module per file is idiomatic Elixir — never merge schemas or contexts
to lower file count (saves zero lines, fights the language). "Savings" = lines deleted, not
relocated. Work top-down; items are ordered highest-gain/lowest-risk first. Run `mix test`
after each item.

## Progress

- [x] `rendering/labels.ex`
- [x] `rendering/liquid_parser.ex` (verified Liquex does not expose a built-in filter/operator subset validator; keeping current implementation)
- [x] `rendering/filters.ex`
- [x] `rendering/post_rendering.ex`
- [x] `rendering/list_archive.ex`
- [x] `rendering/template_selection.ex`
- [x] `rendering/metadata.ex`
- [x] `rendering/links_and_languages.ex`
- [x] `generation/validation.ex`
- [x] `generation/outputs.ex`
- [x] `generation/sitemap.ex`
- [x] `generation/data.ex`
- [x] `generation/paths.ex`
- [x] `generation/renderers.ex`
- [x] `mcp/tools.ex`
- [x] `mcp/server.ex`
- [x] `ai/chat_tools.ex`
- [x] `ai/chat.ex`
- [x] `ai/openai_compatible_runtime.ex`
- [x] `ai/one_shot.ex`
- [x] `ai/secret_key.ex`
- [x] `ai/secret_backend.ex`

---

## 1. Shrink verbose modules (~2,000 lines)

Behaviour-preserving refactors that delete duplicated render/build patterns and hand-rolled
lookups. This is the bulk of real savings.

| Module | Lines | Target | What to cut |
|--------|-------|--------|-------------|
| `rendering/labels.ex` | 91 | ~30 | 28 month-name clauses → list + `Enum.at` |
| `rendering/liquid_parser.ex` | 150 | ~80 | Hand-rolled AST walk for filter/operator validation — only if Liquex exposes a built-in (verify first; if not, keep) |
| `rendering/filters.ex` | 627 | ~450 | Deduplicate macro rendering pattern |
| `rendering/post_rendering.ex` | 290 | ~200 | Pipeline inline variable assignments |
| `rendering/list_archive.ex` | 352 | ~280 | Deduplicate post rendering pattern |
| `rendering/template_selection.ex` | 197 | ~150 | Simplify query logic |
| `rendering/metadata.ex` | 138 | ~100 | Merge menu item builder |
| `rendering/links_and_languages.ex` | 139 | ~100 | Simplify path builders |
| `generation/validation.ex` | 509 | ~350 | Deduplicate timestamp check builders |
| `generation/outputs.ex` | 598 | ~450 | Simplify route path builders |
| `generation/sitemap.ex` | 287 | ~200 | Simplify URL entry builders |
| `generation/data.ex` | 409 | ~320 | Simplify snapshot accumulator |
| `generation/paths.ex` | 238 | ~180 | Deduplicate path builders |
| `generation/renderers.ex` | 174 | ~120 | Simplify fallback rendering |
| `mcp/tools.ex` | 718 | ~500 | Deduplicate tool call patterns |
| `mcp/server.ex` | 346 | ~250 | Simplify TCP server loop |
| `ai/chat_tools.ex` | 1105 | ~800 | Deduplicate tool query patterns |
| `ai/chat.ex` | 992 | ~750 | Simplify streaming state machine |
| `ai/openai_compatible_runtime.ex` | 301 | ~200 | Merge streaming + non-streaming paths |
| `ai/one_shot.ex` | 563 | ~400 | Deduplicate prompt builder pattern |
| `ai/secret_key.ex` | 233 | ~150 | Simplify key resolution chain |
| `ai/secret_backend.ex` | 111 | ~80 | Simplify legacy key fallback |
| `scripting/capabilities/util.ex` | 200 | ~120 | Merge one_arg/two_arg/three_arg into a higher-order fn |
| `desktop/automation.ex` | 333 | ~200 | Use `Desktop.Window` primitives directly |
| `desktop/shell_live/sidebar_events.ex` | 191 | ~50 | Replace 13 handle clauses with a dispatch map |

## 2. Deduplicate private utilities into `BDS.MapUtils` (~50 lines)

`MapUtils.attr/2` already has 124 callers — it is canonical. Remove the scattered private copies:

1. `defp attr/2` → `BDS.MapUtils.attr(attrs, key)`. Files: `tags.ex`, `metadata.ex`, `tasks.ex`, `projects.ex`, `menu.ex`, `import_definitions.ex`
2. `defp maybe_put/3` → `BDS.MapUtils.maybe_put/3`. Files: `tags.ex`, `import_analysis.ex`, `chat_tools.ex`, `import_editor.ex`, `import_definitions.ex`, `analysis_state.ex`, `taxonomy_editing.ex`. For `""`-guard variants (`tags.ex`, `chat_tools.ex`): `BDS.MapUtils.maybe_put(map, key, if(value == "", do: nil, else: value))`
3. `defp blank_to_nil/1` → `BDS.MapUtils.blank_to_nil/1`. ~15 locations across shell_live editors, settings editors, maintenance, import_analysis. For the `"\n"`-guard variant in `git.ex`, inline that guard at the call site.

Keep `map_utils.ex` — it is the canonical home.

## 3. O(1) lookups for static data

### 3a. `lib/bds/ui/registry.ex`
`sidebar_view/1` and `editor_route/1` do `Enum.find` over per-call-rebuilt lists.
```elixir
@sidebar_view_by_id Map.new(sidebar_views(), &{&1.id, &1})
@editor_route_by_id Map.new(editor_routes(), &{&1.id, &1})
def sidebar_view(id), do: @sidebar_view_by_id[id]
def editor_route(id), do: @editor_route_by_id[id]
```

### 3b. `lib/bds/bounded_atoms.ex`
`sidebar_views/0` / `editor_routes/0` recompute `Enum.map(Registry...)` per call. Make them attributes:
```elixir
@sidebar_view_ids Enum.map(Registry.sidebar_views(), & &1.id)
@editor_route_ids Enum.map(Registry.editor_routes(), & &1.id)
defp sidebar_views, do: @sidebar_view_ids
defp editor_routes, do: @editor_route_ids
```

## 4. GenServer → lighter primitive

### 4a. `lib/bds/scripting/job_store.ex` → `Agent`
Pure state container: every `handle_call` is a Map read/write, no `handle_info`, no side effects.
```elixir
defmodule BDS.Scripting.JobStore do
  use Agent
  def start_link(_), do: Agent.start_link(fn -> %{jobs: %{}, runners: %{}} end, name: __MODULE__)
  def get, do: Agent.get(__MODULE__, & &1)
  def update(fun), do: Agent.update(__MODULE__, fun)
end
```
Keep public function names; route them through `Agent.get`/`Agent.update`.

### 4b. `lib/bds/desktop/server.ex` → Bandit child spec
Wraps `Bandit.start_link/1` in a GenServer and stores a PID it never reads. Supervise Bandit directly:
```elixir
def child_spec(opts) do
  Supervisor.child_spec(
    {Bandit, plug: BDS.Desktop.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: port(), startup_log: false},
    id: __MODULE__
  )
end
```
Keep `port/0` and `url/0` as plain module functions.

## 5. Delete dead / single-impl code

- `lib/bds/desktop/shell_live/code_entity_editor.ex` — 0 lines, verified empty.
- `lib/bds/scripting/runtime.ex` — behaviour with one impl (`Lua`). Fold the contract into `lua.ex`, update the alias in `scripting.ex`.

Verify each call site before deleting.

## 6. Inline one-function wrapper files

Inline at the call site, delete the file, `mix test`. One at a time — verify call sites.

| File | Lines | Replacement |
|------|-------|-------------|
| `lib/bds/desktop/error_html.ex` | 9 | inline `"not found"` into `router.ex` |
| `lib/bds/desktop/health_controller.ex` | 9 | inline `"ok"` into `router.ex` |
| `lib/bds/desktop/external_links.ex` | 12 | `Desktop.OS.open_url` at call site |
| `lib/bds/desktop/folder_picker.ex` | 35 | `Desktop.OS` directly |
| `lib/bds/desktop/file_picker.ex` | 35 | `Desktop.OS` directly |
| `lib/bds/desktop/deep_link.ex` | 35 | inline at call site |
| `lib/bds/desktop/overlay.ex` | 35 | `Desktop.Window` directly |
| `lib/bds/rebuild.ex` | 23 | `Task.async_stream` at call site |
| `lib/bds/starter_templates.ex` | 22 | inline into `templates.ex` |

Keep (idiomatic, not over-engineering): `lib/bds.ex` (app entry / namespace root),
`lib/bds/slug.ex` (inline only if a single caller of `BDS.Slug` — grep first),
`lib/bds/desktop/menu_compat.ex` (shared `__using__` macro for `Menu` + `MenuBar`).

---

Final gate after all items: `mix test`, `mix credo --strict`, `mix deps.audit`, `mix dialyzer`. Warnings are errors.
