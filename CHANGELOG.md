# Changelog

All notable changes to mizuya. Versions are git tags (`vX.Y.Z`); the Docker
workflow builds images on tag push.

## Unreleased

### Safety
- Secret gate extended to every stored free-text field: entity name,
  summary, and tags; observation text and its `source` label; relation
  labels; OKF front-matter fields. A secret detected in the entity id
  refuses the upsert outright (ids are referential keys — relations,
  history, FTS, `entity://` URIs — and are never rewritten in place).
  Scanner errors refuse the write, as before.
- `observe`/`add_observation` echo the stored (redacted) text instead of
  the raw input; upserts redact the stored entity (the redacted record
  is what `--json` returns). stderr `WARN` fires for every redacted
  field with detector names only.
- Entity `type` is validated (and lowercased) at the CLI and MCP
  boundaries — an unknown `--type` / `upsert_entity` `type` fails as a
  usage error instead of being stored verbatim.
- `prune-history` with both `--keep` and `--before` now prunes only
  versions breaking **both** bounds (union retention): a recent version
  is no longer dropped just because it ranks beyond `--keep`. Pinned by
  `TestPruneHistoryKeepAndBeforeUnion`; `docs/STORAGE.md` documents the
  semantics.
- Invalid `--since`/`--until`/`--as-of`/`--threshold` values are usage
  errors (exit 2), matching the output contract.
- Dockerfile pins kukicha `v0.86.9` (was `v0.86.5`), matching the
  vendored stdlib.

### Removed
- `distill` — it shelled out to an `openwiki -p` run, and the openwiki
  tool/ecosystem is gone. The `observations.distilled` column, the
  `drift` exclusion for `distilled = 1` rows, and the
  `idx_observations_distilled` index are kept so existing databases
  behave identically (nothing sets the flag anymore).
  `--openwiki-cmd` (a dead flag, validated but never used) went with it.

### Housekeeping
- MCP resources and the completion handler now open the database through
  the same self-initializing, extension-registering pool as every tool
  (`openMCPPool`); the bare `sqlite.OpenPath` path is gone. The server
  also exposes two resources, now documented in the README and
  `docs/output-contract.md`: `entity://list` (Entity[] snapshot) and
  `entity://{id}` (the shallow `get_context` payload).
- Removed unreferenced helpers: `deleteEntity`, `deleteObservation`,
  `unrelate`, `addTag`, `openDB` (no callers in code, tests, or CLI).

### OKF bundle import
- New `import-okf <dir> [--bundle docs]` command imports an OKF v0.2
  knowledge bundle into entities + `references` edges: one entity per
  concept doc (slug = bundle-relative path minus `.md`, e.g.
  `reference/ARCHITECTURE`), root `index.md`/`log.md` skipped per SPEC
  §8/§9. Idempotent; summaries pass the fail-closed secret gate.
  `import-openwiki` remains as a deprecated alias (`--bundle openwiki`).
- Front-matter parsing now binds OKF wire keys natively — the old
  `entityType as "type"` alias transpiled to a json tag that yaml.v3
  ignores, so `type:` was silently dropped; `type: Tool` now maps to
  entity type `tool`.
- Imported entities are tagged `okf` + front-matter `type` + section dir
  (`guides`/`reference`/...) + `status:<status>` + front-matter tags.
- Markdown link resolution uses path cleaning (`../` segments) instead of
  string stripping. `--json` shape unchanged:
  `{"status": "imported", "entities": N, "links": N}` (output contract).

### Fixes
- `upsert` text mode echoed the raw `--name` it had just redacted and
  stored (secret leak onto stdout for anyone piping the confirmation).
  It now prints the stored (redacted) name, and appends the same
  `(redacted N secret(s))` suffix `observe` uses. `upsertEntity` returns
  the redaction count (name + summary + tags), mirroring `addObservation`.
- `observe`/`upsert` committed the row, then exited 1 when the embedding
  provider was unreachable (`cannot refresh embedding`) — a retry trap for
  an append-only store, newly reachable since `MIZUYA_EMBED_*` is bound
  from the environment. Both commands (and the MCP `add_observation` /
  `upsert_entity` tools) now report success: exit 0 / non-error tool
  result, a stderr `WARN`, and — in CLI `--json` — additive
  `"embedding": "deferred"` / `"embedding_error": string` keys. The write
  committed, the stored content hash only advances on a successful
  refresh, and the vector lands on a later touch. The `add_observation`
  confirmation text appends `(embedding deferred)`; `upsert_entity`
  returns the plain `Entity` (deferral on stderr only). See
  `docs/output-contract.md`.

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
- Opening a path that was never `mizuya init`'d no longer fails with
  `no such table: entity_ids_fuzzy` leaving a bare file behind: `openPoolAt`
  runs the idempotent `initDB` on open, so every command self-initializes
  (pre-existing, predates 0.2.0).

### Tests
- `store_test.kuki`, `contract_test.kuki`, `phase3_test.kuki`,
  `bench_test.kuki` (labeled recall benchmark + latency benchmarks).

## 0.1.0 — untagged

Initial CLI + MCP server: entities/relations/observations, FTS5 BM25,
vec1 vector KNN, hybrid RRF, 6 MCP tools.
