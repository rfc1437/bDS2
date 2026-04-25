# bDS2

bDS2 is the Elixir rewrite of bDS, the offline-first desktop blogging workspace in [../bDS](/Users/gb/Projects/bDS). The repository now contains a substantial BEAM application: Ecto persistence, filesystem-backed content workflows, rendering/generation/publishing pipelines, AI and MCP integrations, and a bundled desktop shell served by the Elixir runtime.

The Allium specifications in [specs/](/Users/gb/Projects/bDS2/specs) remain the behavioral contract for the rewrite. For current implementation status and the parity roadmap, see [PLAN.md](/Users/gb/Projects/bDS2/PLAN.md).

## Scope

The rewrite aims to preserve the product behavior of bDS while replacing the technical stack.

Behaviour that should remain stable includes:

- Offline-first editorial workflows.
- Filesystem-backed content with stable frontmatter, media sidecars, templates, scripts, and menu formats.
- Project, post, media, translation, tag, template, generation, preview, publishing, AI, and MCP workflows.
- Generated site output, search behavior, metadata synchronization, and rebuild behavior where those are part of the product contract.

The following are intentionally not part of the behavioral contract:

- The implementation language.
- Desktop container or UI framework.
- ORM choice.
- Internal state management, concurrency model, or runtime libraries.

## Scripting Direction

bDS2 should use Lua as its user-facing scripting language.

The reason is host fit, not language fashion: Lua has a better embedding story for the BEAM than Python does, while still being small, expressive, and suitable for user-authored macros, transforms, and utility scripts. The current direction is:

- Lua script files as the persisted user script format.
- A BEAM-hosted execution boundary with explicit host capabilities instead of unrestricted runtime access.
- Bounded but long-running script execution for user-authored code, with explicit progress reporting through host APIs.

The initial runtime baseline in this repository uses a dedicated Elixir scripting boundary with a Luerl-backed Lua adapter. The goal is to keep scripting integration native to the BEAM while making sandboxing and host capability exposure explicit at the application boundary.

This keeps the scripting surface lightweight and aligned with the Elixir host application. Python remains a possible integration boundary for specialized tasks, but it is no longer the default scripting model for the rewrite.

## Repository Layout

- [mix.exs](/Users/gb/Projects/bDS2/mix.exs): Mix project definition.
- [config/](/Users/gb/Projects/bDS2/config): Elixir and Ecto configuration.
- [lib/](/Users/gb/Projects/bDS2/lib): application bootstrap and shared runtime modules.
- [priv/repo/](/Users/gb/Projects/bDS2/priv/repo): Ecto migrations.
- [specs/](/Users/gb/Projects/bDS2/specs): Allium specs distilled from the existing bDS product and being normalized for implementation-agnostic use.

## macOS Development Setup

If you are setting up a new macOS machine, start with the toolchain.

### 1. Install Xcode Command Line Tools

```bash
xcode-select --install
```

### 2. Install Homebrew

If Homebrew is not already installed:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 3. Install Erlang, Elixir, and SQLite

```bash
brew update
brew install erlang elixir sqlite
```

Verify the installation:

```bash
elixir --version
mix --version
sqlite3 --version
```

### 4. Fetch Dependencies

```bash
cd /Users/gb/Projects/bDS2
mix deps.get
```

### 5. Create the Local Database

```bash
mix ecto.create
mix ecto.migrate
```

### 6. Run Tests

```bash
mix test
```

## Development Notes

- Use `mix test` for validation during development.
- The application behavior is defined by the Allium specs in [specs/](/Users/gb/Projects/bDS2/specs).
- Use [PLAN.md](/Users/gb/Projects/bDS2/PLAN.md) for implementation status and the parity roadmap.
