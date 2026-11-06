# Changelog

All notable changes to mizuya. Versions are git tags (`vX.Y.Z`); the Docker
workflow builds images on tag push.

## 0.2.0 — 2026-11-05

First tagged release (0.1.0 was never tagged). Adopts the core lessons from
huggingface/funes plus consumer (foamy/courier) feedback:

### Append-only beliefs, read-time synthesis
- `entity_history` append-only version log: every `upsert` appends the
  post-update state in the same transaction; no-op upserts don't spam it.
- `observations.supersedes`: a correcting observation links to the one it
  replaces (`observe --supersedes`, MCP `add_observation supersedes`).
  `ObsRow` gains `superseded_by` (inverse link) so stale facts are visibly
  flagged; `context --hide-superseded` / MCP `hide_superseded` filter them.
- Time-travel reads: `--since/--until` on `search`/`context`/`similar`
  (CLI + MCP), `context --as-of YYYY-MM-DD`.
- `drift` reworked onto the history log; superseded observations excluded
  unless `--include-superseded`.
- `prune-history --keep N [--before YYYY-MM-DD] [--dry-run]`: the
  deliberate-deletion exception; newest version per entity always kept.
  Retention policy in `docs/STORAGE.md`.
- Search/similar hits carry `updated_at` + RRF `score`.

### Contracts & ergonomics
- `docs/output-contract.md`: stable `--json` shape of every command
  (additive-only rule), observations pinned newest-first, enforced by
  `contract_test.kuki`.
- Text-mode search/similar print a ready-to-run `→ context --id <id>
  --history` drill-down line per hit.
- MCP tool descriptions state defaults and token cost per call.

### Safety & operations
- Fail-closed secret gate (`scanner.kuki`, pluggable `SecretScanner`,
  offline regex default): secrets redacted as `[REDACTED:<detector>]` on
  every write; scanner error refuses the write. `MIZUYA_SECRET_SCAN=redact`
  (default) or `off`. Redaction count surfaced in `--json`, text mode, and a
  stderr WARN line (detector names only).
- Idempotent `import-openwiki` (re-import is a no-op).
- `docs/STORAGE.md` cost model + history retention policy.

### Fixes
- `hybridSearch` RRF top-k cut was random map order (`sort.ByKeyDesc`
  returns a copy; result was discarded) — found by the new labeled recall
  benchmark, fixed.

### Tests
- `store_test.kuki`, `contract_test.kuki`, `phase3_test.kuki`,
  `bench_test.kuki` (labeled recall benchmark + latency benchmarks).

## 0.1.0 — untagged

Initial CLI + MCP server: entities/relations/observations, FTS5 BM25,
vec1 vector KNN, hybrid RRF, 6 MCP tools.
