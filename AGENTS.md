---
type: Agent Instructions
title: AGENTS.md — mizuya repository guide
description: Guidelines, verification commands, and architecture notes for agents working in mizuya.
tags: [agents, conventions, kukicha, mcp, memory, vector, sqlite]
generated: { by: antigravity/gemini-3.8-flash, at: 2026-09-26T12:51:00-04:00 }
verified: 2026-11-06T01:43:00Z
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
kukicha test . -run=XXX -bench=. -benchtime=200x   # NB: use -flag=value form (see gotchas)

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
- `context`/`get_context` observations are ALWAYS newest-first (`at DESC, id DESC`); consumers take the tail as "most recent".
- Every `ObsRow` carries `supersedes` and `superseded_by`; superseded observations stay visible (flagged) unless `hide_superseded` is passed.
- `prune-history` is the ONLY deliberate deletion from `entity_history` (retention policy in `docs/STORAGE.md`); it always keeps the newest version per entity and fails closed with neither `--keep` nor `--before`.
- Secret redaction must stay visible in every mode: `--json` `redacted` count, text-mode note, stderr `WARN` (detector names only — never log `SecretFinding.Raw`).

## Current work — adopting funes (huggingface/funes) lessons

Tracker lives in [TODO.md](TODO.md) ("Funes lessons" section). Status:

- **Phase 1 — append-only beliefs, read-time synthesis: DONE** (commit `18e5f32`). `entity_history` version log, `observations.supersedes`, `--since/--until/--as-of`, drift rework, `updated_at`+RRF `score` on hits, tests + labeled recall benchmark. See README "Append-only beliefs".
- **Phase 2 — stable output contract + agent ergonomics: DONE.** `docs/output-contract.md` pins every command's `--json` shape (additive-only rule); enforced by `contract_test.kuki`. Text-mode search/similar print a ready-to-run `→ context --id <id> --history` drill-down line per hit; a hit's `id` is the stable drill coordinate (MCP: `get_context`). Keep the "defaults + token cost in tool descriptions" convention for new MCP tools.
- **Phase 3 — safety, idempotency, measurement: DONE.** Fail-closed secret gate in `scanner.kuki` (pluggable `SecretScanner`, regex default, error-never-clean; `MIZUYA_SECRET_SCAN=redact|off`) gating `observe` and upsert summaries (covers import). Idempotent OKF bundle import: `import-okf <dir> [--bundle docs]` (`importOKF` core, tested; `import-openwiki` kept as a deprecated alias) — one entity per concept doc, slug = bundle-relative path, `index.md`/`log.md` skipped, `references` edges from markdown links. `docs/STORAGE.md` cost model: per-entity ≈ text + FTS copy + `2×dim×4` B vectors. All three funes phases are now adopted; TODO.md tracks the tested-and-abandoned retrieval list.
- **Consumer feedback round (foamy/courier): DONE** (commit `2518f4d`) — pinned observation ordering, redaction surfaced in all modes, `prune-history` + retention policy, `superseded_by` flag / `hide_superseded`. See rule 4 above and TODO.md "Consumer feedback".

Design principle behind all of it (from funes' RATIONALE): defer to the reader — keep the raw record intact, resolve obsolescence at read time, no LLM in the ingest path, recall is pulled not pushed.

## Kukicha gotchas observed (2026-11-05, kukicha v0.86.4)

Full write-up with repros: `/tmp/KUKICHA_BUGS.md`.

1. **Bug:** `kukicha test . -bench . -benchtime 200x` treats `200x` as a package target (`FAIL 200x [setup failed]`) — space-separated values of *unrecognized* forwarded flags are not forwarded. Use `-benchtime=200x`.
2. **Bug/edge:** a `*_test.kuki` cannot see helpers from a sibling `*_test.kuki` (`semantic/undefined` at check time), though `go test` merges them. Keep test files self-contained or move shared helpers into a non-test `.kuki` file.
3. **Footgun:** `sort.By`/`ByKey`/`ByKeyDesc` return a sorted *copy*, they do not sort in place. Always bind: `ids := xs |> sort.ByKeyDesc(f)`. Discarding the result silently keeps map order (this caused nondeterministic RRF ranking in `hybridSearch` until fixed).
4. **Tests:** `test.AssertEqual` uses `reflect.DeepEqual` — `int64` (from `db.Count` etc.) vs `int` literal fails even when equal; cast (`count as int`). `regex.MustCompile` rejects non-literal patterns (security lint) — use `regex.Compile` for data-driven patterns. `env.Set`/`Unset` return errors — add `onerr discard` in tests.

<!-- kukicha:start -->
# Kukicha

Kukicha is a readable, statically typed language that transpiles to Go — same toolchain, modules, and semantics — with pipes, `onerr`, enums, if-expressions, and English operators instead of Go's C-style symbol load. This project is a Kukicha project — compile and run `.kuki` files with the `kukicha` compiler (v0.86.7).

The full language + stdlib reference is installed as the `kukicha` skill at [.agents/skills/kukicha/SKILL.md](.agents/skills/kukicha/SKILL.md) — read it before writing or reviewing `.kuki` code. It is compiler-owned and regenerated by `kukicha init` (or the first build after a compiler upgrade); don't hand-edit it.

<!-- kukicha:end -->
