# mizuya

A Kukicha knowledge graph server powered by SQLite with **FTS5 full-text
search**, **vector cosine similarity**, **hybrid RRF ranking**, and an
**MCP stdio server** for AI agent access — built on Kukicha's standard
library (`stdlib/sqlite` + FTS5/vec1 extensions for storage, `stdlib/mcp`
for the agent stdio surface, `stdlib/llm/embeddings` for real providers).
No graph engine, no separate vector database, no extension binaries.

The name *mizuya* (水屋) is the preparation room in a tea house; a good
place to keep everything you've learned within reach.

- `stdlib/sqlite.Open` with WAL + foreign keys via the default pragmas
- Schema + FTS5 virtual tables + triggers defined with plain DDL constants
- JSON-in-SQL with `json_set`, `json_each`, and the `$[#]`
  append path for observations and tags
- BM25 ranking with per-column weights (`bm25(fts, 10, 5, 2, 1)`)
- N-hop graph context lookups via recursive CTEs over the `relations` table
- **vec1 virtual table** for vector KNN with cosine distance, carrying the
  float32 vector plus model/dimension metadata in one store
- **Binary BLOB vector storage** — compact little-endian float32 encoding
- **Real embeddings** via Ollama `embeddinggemma-2:740m` (the default — one shared 768-d text/image/audio/video space) or any OpenAI-compatible API; `MIZUYA_EMBED_PROVIDER=hash` for the offline escape hatch
- **Media attachments** — images, audio, and frame-sampled video stored sha256-addressed under `<db dir>/assets/`, embedded as 768-d vectors (`attach`); bytes are never secret-scanned and every output says so
- **Hybrid search** — Reciprocal Rank Fusion merging FTS5 + vector results
- **Append-only version log** (`entity_history`) + observation supersession
- **Fail-closed secret redaction** on every stored free-text field
- **MCP server** — 8 tools for AI agent integration via `stdlib/mcp`: stdio (client-spawned), or stateless streamable HTTP behind a bearer token for daemonized use

## Build and Run

Built with [Kukicha](https://kukicha.org) 

```
kukicha build mizuya
binary at ./mizuya
```

## Subcommands

| Command   | What it does                                                            |
|-----------|-------------------------------------------------------------------------|
| `init`    | Create the database file and schema (also implicit: every command self-initializes an uninitialized `--db` path via idempotent `initDB` on open) |
| `upsert`  | Create/update an entity (`--id --type --name --summary --tags`); every change is appended to the entity's version history |
| `observe` | Append an observation (`--id --text [--source] [--supersedes <obs-id>]`) and re-embed |
| `attach`  | Attach a media file (`--file [--id entity] [--kind image\|audio\|video] [--caption ...] [--name ...]`); omits `--id` to auto-create a content-addressed media-native entity; bytes are sha256-stored and never scanned — the caption passes the same fail-closed gate as observations |
| `similar-media` | Similarity search over stored media attachments (`--file [--limit] [--kind image\|audio\|video]`); returns attachments (id, entity, kind, caption, distance) instead of entities |
| `relate`  | Create a typed edge (`--src --rel --dst`)                               |
| `search`  | Hybrid search: BM25 + vector RRF (`--query [--limit] [--regex] [--type] [--tag] [--since] [--until]`) |
| `context` | Entity + neighbors + observations (always newest-first) + media attachments (`--id [--depth] [--history] [--since] [--until] [--as-of YYYY-MM-DD] [--hide-superseded]`) |
| `prune-history` | Compact the append-only version log: `--keep N` and/or `--before YYYY-MM-DD`, `--dry-run`; a version is pruned only when it breaks **both** bounds; newest version per entity always kept |
| `similar` | Cosine similarity search (`--id` *or* `--text` *or* `--media <file>`, `[--limit]`, `[--threshold 1-100]`, same filters as `search`); `--media` needs a multimodal provider (`embeddinggemma-2:740m`) so the store and the media query share one vector space |
| `list`    | List entities, optionally filtered by `--type`                          |
| `drift`   | Observations made stale by a later entity change (`--limit`, `--include-superseded`); observations already marked `distilled` are skipped |
| `reembed` | All-or-nothing rebuild of the vector store with the configured provider — required after switching embedding models/dimensions (`--json` for the structured result) |
| `import-okf` | Import an OKF knowledge bundle (`--bundle docs`, default: `docs/` with `index.md`/`log.md` skipped per SPEC §8/§9) into entities + `references` edges; idempotent |
| `import-openwiki` | Deprecated alias for `import-okf --bundle openwiki` |
| `mcp`     | Start the MCP server for AI agent access — stdio, or `--http` (bearer-authed) |

All commands accept the global `--db <path>` (default `.mizuya/mizuya.db`)
and `--json` for structured output. The exact `--json` shapes of every
command are a stable, parseable contract — see
[docs/output-contract.md](docs/output-contract.md). In text mode, search and
similar print a ready-to-run drill-down line per hit (`→ context --id <id>
--history`).

## Secret gate

Every stored free-text field passes a fail-closed secret scanner
(`scanner.kuki`, pluggable `SecretScanner` interface, offline regex engine
by default): detected tokens (AWS/GitHub/OpenAI/Slack/Google keys,
private-key headers, JWTs, generic `key = ...` assignments) are redacted in
place as `[REDACTED:<detector>]` before storing, and a scanner error refuses
the write rather than reporting "clean".

Coverage: entity name, summary, and tags; observation text and its `source`
label; relation labels; imported front-matter fields; media captions and
attachment source labels — all redacted in place. Media **bytes are never
scanned** (the gate is text-only): attachments are marked `[bytes unscanned]`
in every mode and the `media.scanned` column stays 0, so the absence of a
scan is always visible, never silently implied. Entity type is a closed
enum validated (and lowercased) at the
CLI/MCP boundaries. A secret detected in the **entity id** refuses the
upsert outright — ids are referential keys (relations, history, FTS,
`entity://` URIs) and are never rewritten in place. `import-okf` covers its
summaries and names via the same gate.

`observe`/`add_observation` report how many secrets were redacted
(`redacted` field in `--json`, note in text/MCP output) and echo the
*stored* (redacted) text, never the raw input. Upserts redact the stored
entity (that's what `--json` returns). Every redacted field also triggers
a stderr `WARN` log line with detector names (never the secret), so clipping
is visible even when stdout is piped. Control with `MIZUYA_SECRET_SCAN=redact`
(default) or `=off`; any other value is an error. Storage sizing + history
retention policy: [docs/STORAGE.md](docs/STORAGE.md).

## Media attachments

`attach` stores an image, an audio file, or a video on an entity — or, without
`--id`, as its own **media-native entity** (`type: media`, id
`media-<sha256[:12]>`, so re-attaching the same bytes is idempotent).
Video is frame-sampled with ffmpeg (≤10 evenly spaced keyframes, ~1 fps
for short clips) and mean-pooled into a single image-space vector —
the multimodal API takes no video key, so this is the honest
approximation; it needs `ffmpeg`/`ffprobe` in PATH.
Bytes are copied once under `<db dir>/assets/<sha256>.<ext>`; the `media`
table records entity link, mime, size, and a caption that passes the
same fail-closed secret gate as observations. Media bytes are **never**
secret-scanned — every output marks attachments `[bytes unscanned]`.

Embeddings use the configured provider. The default (Ollama +
`embeddinggemma-2:740m`) is one shared text/image/audio/video space, so
no extra configuration is needed — media and text retrieval already live
in one space:

```bash
ollama pull embeddinggemma-2:740m
mizuya attach --file screenshot.png --id deploy-console --caption "red modal after rollback"
mizuya similar --media screenshot.png --limit 5
```

One attachment = one 768-d vector in the `media_vec` index; the caption
(like any entity text) is embedded into the entity's own vector as usual.
Video is frame-sampled with ffmpeg (≤10 evenly spaced keyframes, ~1 fps
for short clips) and mean-pooled into a single image-space vector — the
multimodal API takes no video key, so this is the honest approximation.
Video needs ffmpeg/ffprobe in PATH. Entity text embeddings only share the space
with media when the text provider *is* `embeddinggemma-2:740m`; switching
providers changes the vector dimension (vec1 bakes it at first insert), so
after switching run **`mizuya reembed`** — every entity and media asset is
re-embedded with the configured provider *before* the store drops, so a
provider outage aborts with the store untouched. `similar --media` refuses
cross-dim queries and points at this command.

`reembed` also advances each entity's stored `content_hash`, so the next
`upsert`/`observe` does not re-embed needlessly. Migration safety:
`TestLabeledRecall` passes at recall@5 = 1.00 (floor 0.80) with
`embeddinggemma-2:740m` as the text provider.

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
8 tools that AI agents can use to read and write the knowledge graph:

| MCP Tool         | Description                                               |
|------------------|-----------------------------------------------------------|
| `upsert_entity`  | Create or update an entity (id, type, name, summary, tags); appends to version history |
| `add_observation`| Append an observation (entity_id, text, source, supersedes) |
| `relate`         | Create a typed edge between two entities                  |
| `search`         | Hybrid search (BM25 + vector RRF; optional type/tag/since/until) |
| `get_context`    | Entity + neighbors + observations (newest-first; `superseded_by` flags stale ones) + media `attachments` (each marked unscanned); optional `history`, `since`, `until`, `hide_superseded` |
| `similar`        | Vector similarity search by entity id or text; same filters as `search` |
| `attach_media`   | Attach a media file (image, audio, or video) — `file` (host-local path) or `data_base64` — to an entity, or auto-create a media-native one; bytes are sha256-stored and never secret-scanned; caption passes the text gate |
| `similar_media`  | Vector similarity search over stored media attachments (file or data_base64 query; `kind` filter; returns attachments, not entities) |

### MCP resources

In addition to the tools, the server exposes two read-only resources:

| Resource | Contents |
|----------|----------|
| `entity://list` | Snapshot of all entities (name, type, summary) as JSON — up to 500, newest-updated first |
| `entity://{id}` | Full context for one entity — same payload as the `get_context` tool (entity, outgoing/incoming relations, observations, newest-first) |

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
        "MIZUYA_SECRET_SCAN": "redact"
      }
    }
  }
}
```

### HTTP transport (daemonized use)

`mizuya mcp --http <addr>` serves the same tools over the streamable HTTP
transport in **stateless** mode (each request is self-contained — nothing is
lost on restart), behind a bearer-token gate. stdio stays the default.

```bash
# 1. A token: 64 hex chars, in a file only you can read.
install -d -m 700 ~/.config/mizuya
openssl rand -hex 32 > ~/.config/mizuya/mcp-token && chmod 600 ~/.config/mizuya/mcp-token

# 2. Serve. --db must be absolute when a service manager starts it.
mizuya mcp --db ~/.mizuya/mizuya.db --http 127.0.0.1:8765 --token-file ~/.config/mizuya/mcp-token
```

Clients configure an HTTP MCP server at `http://127.0.0.1:8765/` with the
header `Authorization: Bearer <token>` (the stdlib's own client:
`mcp.BearerConnect(ctx, url, token)`).

Smoke test without an MCP client:

```bash
curl -sN -X POST http://127.0.0.1:8765/ \
  -H "Authorization: Bearer $(cat ~/.config/mizuya/mcp-token)" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-07-28","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

**Fail-closed rules.** HTTP mode refuses to start without a token; the token
comes from `--token-file`, then `MIZUYA_MCP_TOKEN_FILE`, then `MIZUYA_MCP_TOKEN`,
must be at least 32 characters, and token files must be mode 0600. A
non-loopback `--http` address additionally needs `--allow-remote` — the token
travels in plaintext, so anything beyond loopback belongs behind a TLS
terminating reverse proxy. Tokens are compared in constant time and never
logged.

#### User systemd unit

`~/.config/systemd/user/mizuya-mcp.service`:

```ini
[Unit]
Description=mizuya — MCP server (stateless streamable HTTP, loopback)
# Only meaningful if Ollama runs as a *user* service; mizuya degrades
# gracefully when Ollama is down (writes commit, vectors deferred with a WARN).
# Wants=ollama.service
# After=ollama.service

[Service]
Type=exec
ExecStart=%h/.local/bin/mizuya mcp --db %h/.mizuya/mizuya.db --http 127.0.0.1:8765
LoadCredential=mcp_token:%h/.config/mizuya/mcp-token
Environment=MIZUYA_MCP_TOKEN_FILE=%d/mcp_token
EnvironmentFile=-%h/.config/mizuya/env
Restart=on-failure
RestartSec=2

# Hardening: needs only its data dir, loopback, and ffmpeg for video.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.mizuya
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
LockPersonality=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
# Not MemoryDenyWriteExecute: SQLite runs as WASM under wazero — test first.

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload && systemctl --user enable --now mizuya-mcp.service
journalctl --user -u mizuya-mcp -f          # rejected-request and deferred-embed WARNs land here
loginctl enable-linger "$USER"              # only if it must run without a login session
```

`LoadCredential` hands the token to the service as a 0400 file under `%d`
(`$CREDENTIALS_DIRECTORY`), so it never shows up in `systemctl show` and
mizuya's permission check passes. Keep embedding settings identical between
the daemon and your shell — one `~/.config/mizuya/env` that both read — since
two different `MIZUYA_EMBED_*` configurations writing one store means a
`reembed`.

## Embedding Providers

By default mizuya uses **Ollama serving `embeddinggemma-2:740m`** — one
shared 768-d text/image/audio/video space, multimodal out of the box.
The first run needs the model pulled once:

```bash
ollama pull embeddinggemma-2:740m
```

If Ollama is unreachable or the model is missing, **writes still commit** —
the vector is deferred with a stderr `WARN` and lands on a later touch
(embedding is never a write-blocking dependency). `MIZUYA_EMBED_PROVIDER=hash`
is the escape hatch: a deterministic 64-d bag-of-words fallback, no
semantics — for offline machines without Ollama, not the default.

| Variable | Values | Default |
|----------|--------|---------|
| `MIZUYA_EMBED_PROVIDER` | `ollama`, `openai`, `voyage`, `cohere`, or `hash` (offline hatch) | `ollama` |
| `MIZUYA_EMBED_URL` | Base URL for the provider | `http://localhost:11434` (ollama), `https://api.openai.com` (openai) |
| `MIZUYA_EMBED_MODEL` | Model name | `embeddinggemma-2:740m` (ollama), `text-embedding-3-small` (openai) |
| `MIZUYA_EMBED_API_KEY` | API key (required for openai, optional for ollama) | empty |

Switching providers/models changes the vector dimension — run
**`mizuya reembed`** after the switch rather than mixing dimensions
(see above).

### Ollama (the default)

```bash
ollama pull embeddinggemma-2:740m
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
kukicha test . -run=XXX -bench=. -benchtime=200x # latency benchmarks
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
via both keyword and vector match); `context --history` shows the
`uses → sqlite` edge, the observation you just recorded, and the entity's
version log; `similar` puts `sqlite` first for a database query.

## Architecture

```
main.kuki         — CLI entry point + subcommands (including `mcp`)
models.kuki       — Type definitions (Entity, ObsRow, HistoryRow, SearchHit, ...)
schema.kuki       — DDL constants + initDB + migrations
store.kuki        — Entity/relation/observation CRUD, history log, drift, prune
search.kuki       — FTS5 + regex search, filters, vec1 vector storage
hybrid.kuki       — Reciprocal Rank Fusion (FTS5 + vector merge)
embed.kuki        — Embedding provider abstraction (default ollama+embeddinggemma-2:740m, hash hatch, OpenAI-compatible)
scanner.kuki      — Fail-closed secret scanner (pluggable SecretScanner, regex default)
mcp_server.kuki   — MCP server: tool registrations + stdio entry point
mcp_http.kuki     — MCP streamable HTTP transport + bearer-token gate
format.kuki       — Terminal display formatting
*_test.kuki       — store_test, bench_test (labeled recall + benchmarks),
                    contract_test (output contract), phase3_test (scanner/import)
docs/             — output-contract.md (stable --json shapes), STORAGE.md (cost model + retention)
```
