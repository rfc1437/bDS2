# Alignment Tasks

Allium CLI: `/opt/homebrew/bin/allium`. Use `allium check specs/<file>.allium` only when tending a spec; no Allium command is needed for code-only alignment tasks.

Goal: align bDS2 with old bDS behavior. Use the Allium specs as the contract only where they match old bDS. If old bDS and bDS2 agree but the spec differs, tend the spec.

## P0: MCP Proposal Lifecycle (done)

- Old bDS: proposals are in-memory and removed after `accept_proposal` or `discard_proposal`.
- bDS2 now: proposals are persisted and marked `accepted` / `discarded`.
- Spec: matches old bDS; accepted/discarded proposals should no longer exist.
- Action: change bDS2 to remove accepted/discarded proposals, update tests, and remove/adjust terminal-status expectations.
- Status: done.

## P0: MCP Cursor Resources (done)

- Old bDS: `bds://posts{?cursor}` and `bds://media{?cursor}` use base64url cursors, page size 50, and `nextCursor`.
- bDS2 now: first-page resources exist, but cursor URI/resource-template behavior is missing.
- Spec: matches old bDS cursor behavior.
- Action: implement cursor parsing/templates for posts and media resources and add tests for first page, next cursor, invalid cursor, and final page.

## P0: MCP Translation Tools (done)

- Old bDS: exposes `get_post_translations`, `get_media_translations`, and app-gated `upsert_media_translation`.
- bDS2 now: domain translation functions exist, but MCP tools are missing.
- Spec: missing these tools.
- Action: add the tools to `specs/mcp.allium`, implement them in MCP, and test tool listing and call behavior.

## P1: Missing MCP Resources (done)

- Old bDS: also exposes `bds://stats`, `bds://posts/{id}/media`, and `bds://media/{id}/image`.
- bDS2 now: only posts, media, tags, and categories are exposed.
- Spec: missing the old resources.
- Action: add these resources to `specs/mcp.allium`, implement them, and test JSON/blob/error responses.

## P1: MCP Agent Config Surface (done)

- Old bDS: agent config install/remove is a settings UI / IPC action, not an MCP tool.
- bDS2 now: implemented as settings UI action.
- Spec: incorrectly lists install/uninstall in the MCP automation surface.
- Action: tend `specs/mcp.allium` to move agent config out of MCP automation and describe it as settings UI behavior.

## P1: MCP CLI Proposal TTL (done)

- Old bDS: one proposal TTL, 30 minutes.
- bDS2 now: one proposal TTL, 30 minutes.
- Spec: adds `proposal_ttl_cli = 8.hours`.
- Action: remove the CLI-specific TTL from `specs/mcp.allium` or mark it explicitly future/non-current.

## P1: Media Thumbnail Encoding (done)

- Old bDS: small/medium/large WebP quality 80; AI JPEG quality 85.
- bDS2 now: matches old bDS.
- Spec: now specifies WebP quality 80 and AI JPEG quality 85.
- Action: tend `specs/media_processing.allium` to specify WebP quality 80 and AI JPEG quality 85.

## P2: Media Import Event Shape

- Old bDS: imports by source path plus optional metadata in project context.
- bDS2 now: imports with attrs including `source_path` and `project_id`.
- Spec: duplicates `ImportMediaRequested` with conflicting argument order across media specs.
- Action: normalize media specs to one event shape: source path plus project/context, with optional metadata where relevant.

## P2: Import Conflict Resolution Terms

- Old bDS: conflict resolutions are `ignore`, `overwrite`, and `import`.
- bDS2 now: accepts/normalizes `skip -> ignore` and `merge -> overwrite`.
- Spec: says `import`, `skip`, and `merge`.
- Action: tend `specs/editor_misc.allium` to old terms. Optional code cleanup: expose old terms directly in bDS2 UI/events to reduce mapping.

## Execution Order

1. Fix P0 MCP code gaps first: proposal removal, cursor resources, translation tools.
2. Add missing MCP resources after cursor plumbing is in place.
3. Tend MCP specs for agent config and CLI TTL.
4. Tend media specs for thumbnail quality and import event shape.
5. Tend import conflict terminology, then decide whether code cleanup is worth it.