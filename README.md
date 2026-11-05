# mizuya

A Kukicha knowledge graph server powered by SQLite with **FTS5 full-text
search**, **vector cosine similarity**, **hybrid RRF ranking**, and an
**MCP stdio server** for AI agent access — using only `stdlib/sqlite`,
`stdlib/db`, `stdlib/mcp`, `stdlib/fetch`, and `stdlib/cli`.
No graph engine, no separate vector database, no extension binaries.

The name *mizuya* (水屋) is the preparation room in a tea house; a good
place to keep everything you've learned within reach.

- `stdlib/sqlite.Open` with WAL + foreign keys via the default pragmas
- Schema + FTS5 virtual tables + triggers defined with plain DDL constants
- JSON-in-SQL with `json_set`, `json_object`, `json_each`, and the `$[#]`
  append path for observations and tags
- BM25 ranking with per-column weights (`bm25(fts, 10, 5, 2, 1)`)
- N-hop graph context lookups via recursive CTEs over the `relations` table
- **vec1 virtual table** for vector KNN with cosine distance, plus a plain
  `embeddings_raw` side store (the vendored vec1 build is write/search-only)
- **Binary BLOB vector storage** — compact little-endian float32 encoding
- **Real embeddings** via Ollama or OpenAI-compatible APIs (with hash fallback)
- **Hybrid search** — Reciprocal Rank Fusion merging FTS5 + vector results
- **Append-only version log** (`entity_history`) + observation supersession
- **Fail-closed secret redaction** on every write
- **MCP stdio server** — 6 tools for AI agent integration via `stdlib/mcp`

## Build and Run

Built with [Kukicha](https://kukicha.org) 

```
kukicha build mizuya
binary at ./mizuya
```

## Subcommands

| Command   | What it does                                                            |
|-----------|-------------------------------------------------------------------------|
| `init`    | Create the database file and schema                                     |
| `upsert`  | Create/update an entity (`--id --type --name --summary --tags`); every change is appended to the entity's version history |
| `observe` | Append an observation (`--id --text [--source] [--supersedes <obs-id>]`) and re-embed |
| `relate`  | Create a typed edge (`--src --rel --dst`)                               |
| `search`  | Hybrid search: BM25 + vector RRF (`--query [--limit] [--type] [--tag] [--since] [--until]`) |
| `context` | Entity + neighbors + observations, always newest-first (`--id [--depth] [--history] [--since] [--until] [--as-of YYYY-MM-DD] [--hide-superseded]`) |
| `prune-history` | Compact the append-only version log: `--keep N` and/or `--before YYYY-MM-DD`, `--dry-run`; newest version per entity always kept |
| `similar` | Cosine similarity search (`--id` *or* `--text`, `[--limit]`, same filters as `search`) |
| `list`    | List entities, optionally filtered by `--type`                          |
| `drift`   | Observations made stale by a later entity change (`--limit`, `--include-superseded`) |
| `import-openwiki` | Import an OpenWiki corpus (`openwiki/*.md`) into entities + `references` edges; idempotent |
| `distill` | Feed old high-reuse observations to an `openwiki -p` run (`--dry-run` to preview) |
| `mcp`     | Start the MCP stdio server for AI agent access                          |

All commands accept the global `--db <path>` (default `.mizuya/mizuya.db`)
and `--json` for structured output. The exact `--json` shapes of every
command are a stable, parseable contract — see
[docs/output-contract.md](docs/output-contract.md). In text mode, search and
similar print a ready-to-run drill-down line per hit (`→ context --id <id>
--history`).

## Secret gate

All writes pass a fail-closed secret scanner (`scanner.kuki`, pluggable
`SecretScanner` interface, offline regex engine by default): detected
tokens (AWS/GitHub/OpenAI/Slack/Google keys, private-key headers, JWTs,
generic `key = ...` assignments) are redacted in place as
`[REDACTED:<detector>]` before storing, and a scanner error refuses the
write rather than reporting "clean". `observe` reports how many secrets
were redacted (`redacted` field in `--json`, note in text/MCP output).
Control with `MIZUYA_SECRET_SCAN=redact` (default) or `=off`; any other
value is an error. Redactions are surfaced in text mode (`(redacted N
secret(s))` on the observe line) and as a stderr `WARN` log line with
detector names (never the secret), so clipping is visible even when stdout
is piped. Storage sizing + history retention policy:
[docs/STORAGE.md](docs/STORAGE.md).

## Append-only beliefs (funes-style)

Nothing is silently overwritten. Every `upsert` appends the post-update
state to the `entity_history` table (the `entities` row stays the fast
"current view"), and `observe --supersedes <obs-id>` links a correcting
observation to the one it replaces instead of deleting it. Reads can
time-travel: `context --as-of 2026-01-01` shows the latest logged state
from before that date, `--since/--until` bound both `search` and
`context`, and `drift` reports observations made stale by later entity
changes (excluding deliberate supersessions). Search hits carry
`updated_at` and their RRF `score`, so callers can reason about recency
and ranking instead of trusting rank alone.

## MCP Server

The `mcp` subcommand starts a Model Context Protocol stdio server with
6 tools that AI agents can use to read and write the knowledge graph:

| MCP Tool         | Description                                               |
|------------------|-----------------------------------------------------------|
| `upsert_entity`  | Create or update an entity (id, type, name, summary, tags); appends to version history |
| `add_observation`| Append an observation (entity_id, text, source, supersedes) |
| `relate`         | Create a typed edge between two entities                  |
| `search`         | Hybrid search (BM25 + vector RRF; optional type/tag/since/until) |
| `get_context`    | Entity + neighbors + observations (newest-first; `superseded_by` flags stale ones); optional `history`, `since`, `until`, `hide_superseded` |
| `similar`        | Vector similarity search by entity id or text; same filters as `search` |

### Claude Desktop configuration

```json
{
  "mcpServers": {
    "mizuya": {
      "command": "kukicha",
      "args": ["run", "path/to/mizuya/", "--", "mcp", "--db", "/path/to/mizuya.db"]
    }
  }
}
```

Or if you've built the binary:

```json
{
  "mcpServers": {
    "mizuya": {
      "command": "/path/to/mizuya",
      "args": ["mcp", "--db", "/path/to/mizuya.db"],
      "env": {
        "MIZUYA_EMBED_PROVIDER": "ollama",
        "MIZUYA_EMBED_MODEL": "nomic-embed-text",
        "MIZUYA_SECRET_SCAN": "redact"
      }
    }
  }
}
```

## Embedding Providers

By default mizuya uses a deterministic hash embedding (works offline, no
dependencies). For real semantic search, configure an embedding provider:

| Variable | Values | Default |
|----------|--------|---------|
| `MIZUYA_EMBED_PROVIDER` | `ollama`, `openai`, `voyage`, `cohere`, or empty (hash fallback) | empty |
| `MIZUYA_EMBED_URL` | Base URL for the provider | `http://localhost:11434` (ollama), `https://api.openai.com` (openai) |
| `MIZUYA_EMBED_MODEL` | Model name | `nomic-embed-text` (ollama), `text-embedding-3-small` (openai) |
| `MIZUYA_EMBED_API_KEY` | API key (required for openai, optional for ollama) | empty |

### Ollama (recommended for local use)

```bash
# Pull an embedding model
ollama pull nomic-embed-text

# Use it with mizuya
export MIZUYA_EMBED_PROVIDER=ollama
export MIZUYA_EMBED_MODEL=nomic-embed-text
mizuya upsert --id myproject --type project --name "My Project" --summary "..."
mizuya similar --text "semantic search query"
```

### OpenAI-compatible (LiteLLM, vLLM, etc.)

```bash
export MIZUYA_EMBED_PROVIDER=openai
export MIZUYA_EMBED_URL=http://localhost:4000   # LiteLLM proxy
export MIZUYA_EMBED_MODEL=text-embedding-3-small
export MIZUYA_EMBED_API_KEY=sk-...
```

## Testing

```bash
kukicha test . -count=1                          # unit + contract + recall-benchmark tests
kukicha test . -run=XXX -bench=. -benchtime=200x # latency benchmarks (use -flag=value form)
```

`bench_test.kuki` also runs `TestLabeledRecall` (floor: recall@5 >= 0.80) —
keep it green when touching retrieval; record tried-and-abandoned ideas in
TODO.md.

## End-to-end walkthrough

```bash
kukicha run . -- init

kukicha run . -- upsert \
    --id kukicha --type project \
    --name "Kukicha Language" \
    --summary "Go superset with pipes, onerr, and enums" \
    --tags lang,compiler,go

kukicha run . -- upsert \
    --id sqlite --type tool \
    --name "SQLite" \
    --summary "Embedded SQL database with FTS5 and JSON" \
    --tags db,embedded,fts

kukicha run . -- relate --src kukicha --rel uses --dst sqlite

kukicha run . -- observe \
    --id kukicha --text "Added pipe operator support in v0.0.29"

# change your mind later — the old observation stays, linked:
kukicha run . -- observe --id kukicha --text "Pipes landed in v0.1.0" \
    --supersedes <obs-id-from-context-json>

kukicha run . -- search --query "embedded database"
kukicha run . -- context --id kukicha --history
kukicha run . -- similar --text "fast database engine"
```

Expected: the `search` query ranks `sqlite` first (hybrid RRF boosts it
via both keyword and vector match); `context` shows the `uses → sqlite`
edge and the observation you just recorded; `similar` puts `sqlite` ahead
of `vllm-h100` for a database query, and vice versa for an ML query.

## Architecture

```
main.kuki         — CLI entry point + subcommands (including `mcp`)
models.kuki       — Type definitions (Entity, ObsRow, HistoryRow, SearchHit, ...)
schema.kuki       — DDL constants + initDB + migrations
store.kuki        — Entity/relation/observation CRUD, history log, drift, prune
search.kuki       — FTS5 + regex search, filters, vec1 vector storage
hybrid.kuki       — Reciprocal Rank Fusion (FTS5 + vector merge)
embed.kuki        — Embedding provider abstraction (Ollama, OpenAI, ..., hash fallback)
scanner.kuki      — Fail-closed secret scanner (pluggable SecretScanner, regex default)
mcp_server.kuki   — MCP stdio server with 6 tool registrations
format.kuki       — Terminal display formatting
*_test.kuki       — store_test, bench_test (labeled recall + benchmarks),
                    contract_test (output contract), phase3_test (scanner/import)
docs/             — output-contract.md (stable --json shapes), STORAGE.md (cost model + retention)
```
