---
type: Agent Instructions
title: AGENTS.md — mizuya repository guide
description: Guidelines, verification commands, and architecture notes for agents working in mizuya.
tags: [agents, conventions, kukicha, mcp, memory, vector, sqlite]
generated: { by: antigravity/gemini-3.8-flash, at: 2026-09-26T12:51:00-04:00 }
verified: 2026-11-23T00:00:00Z
stale_after: 2026-12-26T00:00:00Z
status: stable
sources:
  - id: repo-tree
    resource: /
    title: Repository source tree
---

# AGENTS.md — mizuya repository guide

Guidelines, verification commands, and architecture notes for agents working in `mizuya`.

## Overview

`mizuya` is an MCP server providing persistent long-term memory, entity graphs, and observation tracking for AI agents. It uses SQLite for structured storage and vector search, exposed through Model Context Protocol (`stdlib/mcp`) tools and resources.

## Commands

```bash
# Type check all packages
kukicha check ./...

# Format check
kukicha fmt --check --json .

# Auto-format
kukicha fmt -w .

# Build executable (outputs ./mizuya)
kukicha build .

# Run unit tests (transpiles *_test.kuki, then go test)
kukicha test . -count=1

# Benchmarks + labeled recall check
kukicha test . -run=XXX -bench=. -benchtime=200x   # latency benchmarks

go test ./...   # also works on the transpiled artifacts
```

## Critical Rules & Invariants

### 1. MCP Tool Signatures
- Tools registered with `stdlib/mcp` should declare explicit argument and return types using `mcp.Tool` or `mcp.ToolWithOpts`.
- Fallible operations inside tool handlers should return error values to let MCP handle failure responses cleanly.

### 2. Binary Cleanup
Building with `kukicha build .` produces a local binary (`./mizuya`). Delete the binary and temporary `main.go` after test builds before staging. Generated `*.go` files (including transpiled `*_test.go`) are gitignored — commit `.kuki`, never brewed `.go`.

### 3. Append-only belief model (since 18e5f32)
Never silently overwrite what an entity was. `upsertEntity` appends the post-update state to `entity_history` in the same transaction; observations link corrections via `observations.supersedes` instead of replacing. Reads time-travel with `--since/--until/--as-of`. `observations.at` and `entity_history.changed_at` use millisecond stamps (`strftime('%Y-%m-%d %H:%M:%f','now')`) so same-second ordering is exact; date filters validate real calendar dates via `datetime.Parse(s, datetime.LayoutDate)`. When changing ranking or retrieval, keep `TestLabeledRecall` in `bench_test.kuki` green (floor: recall@5 >= 0.80) and record what was tried and abandoned in TODO.md.

### 4. Consumer-facing contracts (since 2518f4d)
These are pinned in `docs/output-contract.md` and guarded by `contract_test.kuki` / `store_test.kuki` — do not change them without a contract note:
- `context`/`get_context` observations are ALWAYS newest-first (`at DESC, id DESC`); consumers take the first N as "most recent".
- Every `ObsRow` carries `supersedes` and `superseded_by`; superseded observations stay visible (flagged) unless `hide_superseded` is passed.
- `prune-history` is the ONLY deliberate deletion from `entity_history` (retention policy in `docs/STORAGE.md`); it always keeps the newest version per entity and fails closed with neither `--keep` nor `--before`.
- Secret redaction must stay visible in every mode: observe `--json` `redacted` count and text-mode note, and a stderr `WARN` for *every* redacted field on any write (name, summary, tags, observation text/source, relation labels; detector names only — never log `SecretFinding.Raw`). Upsert echoes the redacted `Entity` it stored.

### 5. Entity vector storage
- `embeddings_vec` is the authoritative entity vector store: one vec1 row carries `vector`, `entity_id`, `model`, and `dim`. Do not reintroduce `embeddings_raw` or another duplicate vector table.
- `getEmbedding` reads `embeddings_vec.vector` directly. Keep migration tests covering both historical vec1 layouts and the repeated delete/insert tombstone-compression path (`reembed_test.kuki`).
- `media_raw` is still a deliberate side store; do not assume entity-vector changes apply to media until it receives its own migration and regression tests.

## Releases

1. Keep `CHANGELOG.md` as the release record: move `## Unreleased` to the new semver version and date only when the release is ready.
2. Verify the `Dockerfile` compiler pin matches the Kukicha version documented in the compiler-owned block above.
3. Run `kukicha check ./...`, `kukicha fmt --check --json .`, and `MIZUYA_EMBED_PROVIDER=hash kukicha test . -count=1`.
4. Remove generated Go artifacts, commit the release, and create an annotated `vX.Y.Z` tag. The Docker workflow publishes tags matching `v*`.

<!-- kukicha:start -->
# Kukicha

Kukicha is a readable, statically typed language that transpiles to Go — same toolchain, modules, and semantics — with pipes, `onerr`, enums, if-expressions, and English operators instead of Go's C-style symbol load. This project is a Kukicha project — compile and run `.kuki` files with the `kukicha` compiler (v0.86.12).

The full language + stdlib reference is installed as the `kukicha` skill at [.agents/skills/kukicha/SKILL.md](.agents/skills/kukicha/SKILL.md) — read it before writing or reviewing `.kuki` code. It is compiler-owned and regenerated by `kukicha init` (or the first build after a compiler upgrade); don't hand-edit it.

<!-- kukicha:end -->
