# TODO

## SQLite extension opportunities

mizuya already wires up `vec1` via `stdlib/sqliteext`. The same seam takes any
`ext/*` package from `github.com/ncruces/go-sqlite3` with one line:

```kukicha
sqliteext.Register(pool, theirext.Register) onerr return
```

The candidates below are ordered by expected payoff for mizuya specifically.

### High value

- [ ] **`uuid` — uuid7 primary keys for relations and observations.**
  Replace the Go-side ID generation paths and let SQLite fill in time-ordered
  uuid7s as column defaults. Better B-tree locality than v4; no `crypto/rand`
  import on the Kukicha side.
  Touches: `schema.kuki` (add `DEFAULT uuid7()` on relevant columns),
  drop any Go-side UUID code if/when added.

- [ ] **`closure` — N-hop graph queries for `context`.**
  `outgoingContext` / `incomingContext` in `store.kuki` only walk one hop.
  A closure virtual table over `relations` would give us "everything reachable
  from id X within k hops" without a recursive CTE. Natural fit for an
  `--depth` flag on `mizuya context` and for the MCP `get_context` tool.
  Touches: `schema.kuki` (declare the closure vtable),
  `store.kuki` (new `reachableContext` function), `main.kuki` + `mcp_server.kuki`
  (expose `--depth`).

- [ ] **`regexp` — regex queries alongside FTS5.**
  FTS5 tokenization mangles code identifiers, version strings, and structured
  IDs. `WHERE name REGEXP '^kuk'` or `WHERE data REGEXP 'v0\.[0-9]+\.[0-9]+'`
  picks up cases the porter-stemmed FTS index misses. Pairs cleanly with
  the existing `search` subcommand as a `--regex` mode.
  Touches: `search.kuki` (new `regexSearch`), `main.kuki` (flag wiring).

- [ ] **`unicode` — correct case-insensitive matching for non-ASCII names.**
  SQLite's built-in `lower()` is ASCII-only, so any entity name with
  diacritics or non-Latin scripts compares wrong. The `unicode` extension
  ships proper Unicode upper/lower/like plus NFC/NFD normalization. Worth
  doing before mizuya gets used outside English-only corpora.
  Touches: `store.kuki` (swap `lower()` calls in any case-insensitive lookups),
  `schema.kuki` if we add normalized-name indexes.

### Medium value

- [ ] **`hash` — content-addressed change detection.**
  `sha256(data)` over the entity JSON column would let us skip re-embedding
  when the text corpus hasn't changed. Currently `doUpsert` and `doObserve`
  always re-run `embedText` — fine for the toy hash embedder, expensive once
  ollama/openai are configured.
  Touches: `models.kuki` (add `content_hash` column to `entities`),
  `store.kuki` (compute + compare in upsert/observe paths).

- [ ] **`stats` — percentile distance thresholds for `similar`.**
  Right now `similar` returns the top-k. With `percentile(distance, 0.10)`
  we could instead return "everything in the closest 10% of distances",
  which is more useful when k is unknown. Cheap quality-of-life addition.
  Touches: `search.kuki` (alternate query), `main.kuki` (`--threshold` flag).

- [ ] **`spellfix1` — fuzzy entity-id resolution.**
  Typos in `--id sqilte` currently fail with "entity not found". A spellfix1
  vtable over the entity ids gives a "did you mean sqlite?" path for the CLI
  and MCP tool calls.
  Touches: new `suggest.kuki`, `main.kuki` error path.

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
