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
- 1-hop graph context lookups via the `relations` table
- `sqlite.CreateBlobFunctionFloat` to register a pure-Kukicha cosine-distance UDF
  that operates on binary BLOB vectors with zero parse overhead
- **Binary BLOB vector storage** — compact little-endian float64 encoding
  (~3× smaller than JSON text arrays, no deserialization in the UDF hot path)
- **Real embeddings** via Ollama or OpenAI-compatible APIs (with hash fallback)
- **Hybrid search** — Reciprocal Rank Fusion merging FTS5 + vector results
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
| `upsert`  | Create/update an entity (`--id --type --name --summary --tags`)         |
| `observe` | Append an observation (`--id --text [--source]`) and re-embed           |
| `relate`  | Create a typed edge (`--src --rel --dst`)                               |
| `search`  | Hybrid search: BM25 + vector RRF (`--query [--limit]`)                  |
| `context` | Entity + outgoing/incoming 1-hop neighbors + observation log (`--id`)   |
| `similar` | Cosine similarity search (`--id` *or* `--text`, `[--limit]`)            |
| `list`    | List entities, optionally filtered by `--type`                          |
| `mcp`     | Start the MCP stdio server for AI agent access                          |

All commands accept the global `--db <path>` (default `.mizuya/mizuya.db`)
and `--json` for structured output.

## MCP Server

The `mcp` subcommand starts a Model Context Protocol stdio server with
6 tools that AI agents can use to read and write the knowledge graph:

| MCP Tool         | Description                                               |
|------------------|-----------------------------------------------------------|
| `upsert_entity`  | Create or update an entity (id, type, name, summary, tags)|
| `add_observation`| Append an observation to an entity                        |
| `relate`         | Create a typed edge between two entities                  |
| `search`         | Hybrid search (BM25 + vector RRF)                         |
| `get_context`    | Entity + 1-hop neighbors + observations                   |
| `similar`        | Vector similarity search by entity id or text             |

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
        "MIZUYA_EMBED_MODEL": "nomic-embed-text"
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
| `MIZUYA_EMBED_PROVIDER` | `ollama`, `openai`, or empty (hash fallback) | empty |
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

## End-to-end walkthrough

```bash
kukicha run examples/mizuya/ -- init

kukicha run examples/mizuya/ -- upsert \
    --id kukicha --type project \
    --name "Kukicha Language" \
    --summary "Go superset with pipes, onerr, and enums" \
    --tags lang,compiler,go

kukicha run examples/mizuya/ -- upsert \
    --id sqlite --type tool \
    --name "SQLite" \
    --summary "Embedded SQL database with FTS5 and JSON" \
    --tags db,embedded,fts

kukicha run examples/mizuya/ -- upsert \
    --id vllm-h100 --type config \
    --name "vLLM on H100" \
    --summary "Inference server deployment notes" \
    --tags ml,gpu,inference

kukicha run examples/mizuya/ -- relate --src kukicha --rel uses --dst sqlite

kukicha run examples/mizuya/ -- observe \
    --id kukicha --text "Added pipe operator support in v0.0.29"

kukicha run examples/mizuya/ -- search --query "embedded database"
kukicha run examples/mizuya/ -- context --id kukicha
kukicha run examples/mizuya/ -- similar --text "fast database engine"
```

Expected: the `search` query ranks `sqlite` first (hybrid RRF boosts it
via both keyword and vector match); `context` shows the `uses → sqlite`
edge and the observation you just recorded; `similar` puts `sqlite` ahead
of `vllm-h100` for a database query, and vice versa for an ML query.

## Architecture

```
main.kuki         — CLI entry point + subcommands (including `mcp`)
models.kuki       — Type definitions (Entity, Relation, SearchHit, etc.)
schema.kuki       — DDL constants + initDB
store.kuki        — Entity/relation/observation CRUD
search.kuki       — FTS5 search, binary vector storage, cosine distance UDF
embed.kuki        — Embedding provider abstraction (Ollama, OpenAI, hash fallback)
hybrid.kuki       — Reciprocal Rank Fusion (FTS5 + vector merge)
mcp_server.kuki   — MCP stdio server with 6 tool registrations
format.kuki       — Terminal display formatting
```
