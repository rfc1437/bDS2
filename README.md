# bDS2

bDS2 is the Elixir rewrite of bDS, the offline-first desktop blogging workspace in [../bDS](/Users/gb/Projects/bDS). This repository is the new implementation baseline: Elixir for the application core, Ecto for persistence, and a desktop shell to be selected as the rewrite matures.

The repository currently contains a minimal Elixir/OTP foundation plus a set of Allium specifications in [specs/](/Users/gb/Projects/bDS2/specs). Those specs should define application behavior, file contracts, and user-visible workflows without tying the rewrite to a specific implementation stack.

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
- Bounded script execution for user-authored code.

This keeps the scripting surface lightweight and aligned with the Elixir host application. Python remains a possible integration boundary for specialized tasks, but it is no longer the default scripting model for the rewrite.

## Repository Layout

- [mix.exs](/Users/gb/Projects/bDS2/mix.exs): Mix project definition.
- [config/](/Users/gb/Projects/bDS2/config): Elixir and Ecto configuration.
- [lib/](/Users/gb/Projects/bDS2/lib): application bootstrap and shared runtime modules.
- [priv/repo/](/Users/gb/Projects/bDS2/priv/repo): Ecto migrations.
- [specs/](/Users/gb/Projects/bDS2/specs): Allium specs distilled from the existing bDS product and being normalized for implementation-agnostic use.

## macOS Development Setup

This machine does not have Elixir installed yet, so start with the toolchain.

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

## Current Elixir Baseline

The initial scaffold is intentionally small:

- OTP application startup in [lib/bds/application.ex](/Users/gb/Projects/bDS2/lib/bds/application.ex).
- Ecto repository in [lib/bds/repo.ex](/Users/gb/Projects/bDS2/lib/bds/repo.ex).
- Environment config in [config/config.exs](/Users/gb/Projects/bDS2/config/config.exs), [config/dev.exs](/Users/gb/Projects/bDS2/config/dev.exs), [config/test.exs](/Users/gb/Projects/bDS2/config/test.exs), and [config/runtime.exs](/Users/gb/Projects/bDS2/config/runtime.exs).
- Basic test bootstrap in [test/](/Users/gb/Projects/bDS2/test).

This is not yet the desktop application. It is the base runtime that future work will extend with the domain model, persistence layer, content pipelines, and desktop-facing boundaries.

## Spec Hygiene

When editing files in [specs/](/Users/gb/Projects/bDS2/specs):

- Keep user-visible workflows, content formats, and compatibility rules explicit.
- Keep behavior that affects imported data, generated output, or persisted content.
- Remove references to Rust, TypeScript, Electron, React, specific crates, specific packages, and other implementation choices unless the choice itself is a product requirement.

## Next Steps

1. Translate the core content and project specs into Ecto schemas and migrations.
2. Choose the desktop shell and boundary architecture for the Elixir application.
3. Add executable tests that map directly to the Allium specifications.
