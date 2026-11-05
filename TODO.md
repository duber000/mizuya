# TODO

## SQLite extension opportunities

mizuya already wires up `vec1` via `stdlib/sqliteext`. The same seam takes any
`ext/*` package from `github.com/ncruces/go-sqlite3` with one line:

```kukicha
sqliteext.Register(pool, theirext.Register) onerr return
```

The candidates below are ordered by expected payoff for mizuya specifically.

### High value

- [x] **`uuid` — uuid7 primary keys for observations.** *(observations
  are now a real table with `id TEXT PRIMARY KEY DEFAULT (uuid(7))`.
  Entities still use user-supplied slugs by design; relations still use
  the composite `(src, rel, dst)` PK.)*

- [x] **`closure` — N-hop graph queries for `context`.** *(implemented via
  recursive CTE in `store.kuki`; the ncruces `closure` ext is hardcoded
  to integer ids and doesn't fit our TEXT slug PKs. `--depth` is wired
  on `mizuya context` and on the MCP `get_context` tool.)*

- [x] **`regexp` — regex queries alongside FTS5.** *(wired as `--regex`
  on `mizuya search`; matches against id, name, and data columns.)*

- [x] **`unicode` — correct case-insensitive matching for non-ASCII names.**
  *(registered as a precondition — no current SQL paths use `lower()`,
  `LIKE`, or `COLLATE`, and FTS5 is already unicode-aware via
  `unicode61`. With the ext loaded, any future case-insensitive query
  path picks up Unicode-correct upper/lower/like + normalize/unaccent
  for free.)*

### Medium value

- [x] **`hash` — content-addressed change detection.** *(implemented
  app-side via `stdlib/crypto.SHA256` rather than the SQL extension —
  the corpus is assembled in Go anyway, so a `content_hash` column on
  `entities` plus `reEmbedIfChanged` in `store.kuki` is enough. CLI
  upsert/observe and the matching MCP tools skip the embed-provider
  round-trip when the corpus is unchanged. Pre-hash rows re-embed
  once on next touch, then settle.)*

- [x] **`stats` — percentile distance thresholds for `similar`.** *(wired
  as `--threshold N` (1-100) on the CLI and the MCP `similar` tool;
  uses `percentile()` aggregate over the full distance set.)*

- [x] **`spellfix1` — fuzzy entity-id resolution.** *(wired into the
  CLI error paths for `context`, `observe`, and `similar --id`, plus
  the matching MCP tools. The vtab is rebuilt from `entities.id` on
  every pool open via `refreshFuzzyIds`; switch to incremental
  maintenance if entity churn ever makes that hot.)*

### Low value / situational

- [ ] **`ipaddr` — only matters if mizuya ever stores request logs.**
  Not relevant to the current entity/relation/observation model. Worth
  remembering if we add a `traffic` or `audit` table later.

- [ ] **`array` — JOIN against an input list of ids.**
  Useful for batch operations (`upsert --ids a,b,c`). Marginal today;
  consider if/when a bulk import path appears.

- [ ] **`bloom` — membership checks at scale.**
  Only earns its keep past ~100k entities. Premature for now.

### Out of scope

- **`fileio`, `blobio`, `lines`, `csv`** — these turn SQL into a file-system
  reader. Powerful for bulk import scripts but a footgun for a long-running
  MCP server. If we add an `import` subcommand, register them only inside
  that command's connection, not globally.

## Other follow-ups (not extension-related)

- [ ] **Trained vec1 index.** Migration uses `{index:"flat"}` (brute-force
  scan). Once we have a representative corpus, run `vec1_train` and switch
  the rebuild config — same schema, no app changes. Pays off past a few
  thousand entities.

- [ ] **Drop the `vec_raw` side-copy column** if a future vec1 release lets
  the indexed `vector` column read back as the original BLOB.

## Funes lessons (from huggingface/funes) — adoption tracking

Phase 1 — append-only beliefs, read-time synthesis — **done**:

- [x] `entity_history` append-only version log; every `upsert` appends the
      post-update state in the same transaction (no-op upserts skip the
      append). `context --history` / MCP `get_context history=true` expose it.
- [x] `observations.supersedes` — a correcting observation links to the one
      it replaces (`observe --supersedes`, MCP `add_observation supersedes`).
- [x] Time-travel reads: `--since/--until` on `search`/`context`/`similar`
      (CLI + MCP), `context --as-of YYYY-MM-DD` via `entityStateAt`.
- [x] `drift` reworked: staleness = a logged entity version newer than the
      observation; explicitly superseded observations are excluded unless
      `--include-superseded`.
- [x] Search hits carry `updated_at` + RRF `score`; ranking stays
      relevance-first, age on demand (funes' model).
- [x] Labeled recall benchmark (`bench_test.kuki`: `TestLabeledRecall`,
      floor recall@5 >= 0.80) + latency benchmarks (`-bench .`). This
      already caught a real bug: `sort.ByKeyDesc` returns a copy, so the
      RRF top-k cut was random map order.

Phase 2 — provenance/stable output contract + agent ergonomics — pending:

- [ ] Document the exact `--json` output shape of every command as a stable
      contract ("don't parse loosely", like funes' agent format).
- [ ] Drill-down hints on hits (funes' `→ get <session> --from --to` line).

Phase 3 — safety, idempotency, measurement — pending:

- [ ] Fail-closed secret scanner (pluggable trait, error-not-clean) gating
      `import-openwiki` / optionally `observe`.
- [ ] Idempotent import: content-hash dedup of observations; write-temp-
      then-rename for import files.
- [ ] `docs/STORAGE.md` cost model (~bytes/entity = dim*4 + text), like
      funes' storage.md.
- [ ] Keep a "tested and abandoned" list for retrieval ideas (MMR,
      abstention thresholds, reranker) — only keep what beats the labeled
      benchmark.
