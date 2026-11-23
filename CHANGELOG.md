# Changelog

All notable changes to mizuya. Versions are git tags (`vX.Y.Z`); the Docker
workflow builds images on tag push.

## 0.3.1 — 2026-11-22

### Fixes
- Docker release images now move the compiler's `/src` output to `/mizuya`.
  Kukicha names its executable after the build directory, so the `v0.3.0`
  image workflow failed after a successful compile.
- The CLI and MCP server now report version `0.3.1` (previously `0.2.0`).

## 0.3.0 — 2026-11-22

### Breaking
- **The default embedding provider is now Ollama serving
  `embeddinggemma-2:740m`** — previously the deterministic hash fallback
  (offline, 64-d). Out-of-box behavior changes: writes now attempt a
  localhost:11434 embed (a couple of seconds each, cached after first
  use), multimodal is on by default (`attach`, `similar --media`,
  `similar-media`/`similar_media` work with zero configuration after one
  `ollama pull embeddinggemma-2:740m`), and existing vector stores must
  run `mizuya reembed` once (64→768-d; mixed stores are refused by the
  dim guards). Unreachable/missing model degrades to writes-commits-with
  a stderr WARN deferral — never a blocked write. The offline escape
  hatch is now `MIZUYA_EMBED_PROVIDER=hash` (previously the default).
  `MIZUYA_EMBED_MODEL` for `ollama` now defaults to
  `embeddinggemma-2:740m` (was `nomic-embed-text`). Unit tests and the
  labeled recall harness are hermetic (pin `hash` when the env doesn't
  override). Internal users only.

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
- Dockerfile pins kukicha `v0.86.12`, matching the compiler and vendored
  stdlib.

### Media attachments (embeddinggemma-2)
- New `attach` command and 7th MCP tool `attach_media`: stores image and
  audio files sha256-addressed under `<db dir>/assets/` (bytes deduped,
  never secret-scanned — every output marks `[bytes unscanned]` and
  `media.scanned` is always 0), links them to an existing entity or
  auto-creates a content-addressed media-native entity (`type: media`,
  id `media-<sha256[:12]>`; re-attaching the same bytes is idempotent).
  The caption passes the same fail-closed secret gate as observations.
- Media embeddings are one 768-d unit-norm vector per attachment in a new
  `media_vec` vec1 table + `media_raw` side store (the entity-embedding
  contract is untouched); a provider outage defers the vector instead of
  failing the write, same fail-soft contract as entity re-embeds.
- Validated end-to-end with Ollama `embeddinggemma-2:740m` (object input
  `{"image"|"audio": b64}` via `/v1/embeddings`): `context`/`get_context`
  and the `entity://{id}` resource now list newest-first `attachments`
  (additive-optional in the contract); `similar --media <file>` queries
  the shared text/image/audio space against entity embeddings (refuses
  when the stored text vectors were built with a different
  provider/dimension). Video ingest arrived in the follow-up entry below
  (sampled keyframes, mean-pooled — the multimodal API takes no video key).
- Video attachments: `attach --file clip.mp4` frame-samples with ffmpeg
  (≤10 evenly spaced frames, ~1 fps for short clips) and mean-pools into
  one vector on the attachment; `similar --media` and `similar-media`/
  `similar_media` accept a video query the same way. `reembed`
  re-derives video vectors through the same extraction path (verified
  end-to-end). Requires ffmpeg/ffprobe in PATH; without it, video attach
  fails fast with a clear error and nothing is stored.
- Bug fix: `MIZUYA_EMBED_MODEL` values containing a colon (Ollama tags
  like `embeddinggemma-2:740m`) were split into provider/model by the
  client builder; the model is now passed through verbatim.
- New `similar-media` command and 8th MCP tool `similar_media`:
  KNN over the `media_vec` index with the query embedded via the
  configured provider (dim-guarded against `media_raw`); returns
  attachments (id, entity_id, kind, caption, distance) — the "which
  screenshot/audio is this like?" query. Verified end-to-end with
  Ollama (identical file ranks distance 0).
- New `reembed` command (all-or-nothing, one transaction): rebuilds
  `embeddings_vec` with the configured provider — and
  `media_vec`/`media_raw` when a provider is set — for switching
  embedding models/dimensions. Every vector is computed before the store
  drops, so a provider outage aborts with nothing modified; `content_hash`
  advances to match. `similar --media` points here on dim mismatch.
  TestLabeledRecall recall@5 = 1.00 with embeddinggemma-2:740m.

### Removed
- Entity vectors no longer duplicate storage in `embeddings_raw`. vec1 now
  carries `model` and `dim` metadata alongside the vector; `similar --id`
  reads the vector directly. Startup migrates both historical vec1 layouts
  transactionally and drops the obsolete side table, halving entity vector
  storage. `media_raw` remains until media receives the same migration.
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
