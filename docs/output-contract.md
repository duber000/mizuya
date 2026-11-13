# mizuya output contract

Every command's `--json` output is a **stable contract, not a presentation** —
scripts and agents may parse it strictly. Plain (non-`--json`) output is for
humans and may change freely; the `→ ...` drill-down lines it prints are the
machine-useful part of text mode.

Stability rules:

- Field names and types below are frozen. New *optional* fields may be added
  (additive-only); nothing is renamed or removed without a major version bump.
  Two such optional fields exist today: `upsert` / `observe` add
  `"embedding": "deferred"` and `"embedding_error": string` to their
  `--json` payloads when the write committed but the embedding provider
  could not be reached. The command still exits 0 — non-zero means the
  write did not land — and a stderr WARN line reports the deferral in
  every mode. The row keeps its text and gains a vector on a later touch
  (the stored content hash only advances on a successful refresh).
- Errors in `--json` mode print as `{"error": "<message>"}`. Runtime failures exit 1;
  usage mistakes (a missing required flag, an invalid flag combination or value)
  exit 2 — same JSON shape, different exit code, so a `--json` consumer reads every
  failure as JSON while distinguishing usage errors from runtime errors. In text mode
  a runtime failure prints `error: <message>` (exit 1) and a usage mistake prints
  `usage error: <message>` or the parse failure plus help (exit 2).
- Drill-down coordinate: any search/similar hit's `id` is the stable handle —
  `mizuya context --id <id> --json` (CLI) or the MCP `get_context` tool with
  `id: <hit.id>` returns its observations (each with its own `id`) and,
  with `--history` / `history: true`, its append-only version log.
- **Ordering pin:** the `observations` array in `context` / `get_context`
  output is always newest-first — `ORDER BY at DESC, id DESC` — and always
  includes superseded observations unless `hide_superseded` is set (they are
  flagged via `superseded_by`). Consumers taking "the first N as most recent"
  can rely on this order.

## Shared shapes

```jsonc
Entity      = { "id": string, "type": string, "name": string,
                "data": string /* JSON-encoded object: {"summary": string, "tags": [string]} */,
                "created_at": string /* UTC "YYYY-MM-DD HH:MM:SS" */,
                "updated_at": string }
ObsRow      = { "id": string /* uuid7 */, "text": string, "source": string,
                "at": string /* UTC, millisecond precision */,
                "supersedes": string /* obs id this one corrects, or "" */,
                "superseded_by": string /* obs id that corrects this one, or "" — a non-empty value means DO NOT ACT on this fact */ }
HistoryRow  = { "id": string, "entity_id": string, "type": string, "name": string,
                "data": string /* JSON-encoded, same shape as Entity.data */,
                "changed_at": string /* UTC, millisecond precision */ }
SearchHit   = { "id": string, "type": string, "name": string, "summary": string,
                "updated_at": string, "score": number /* RRF score; 0 for regex/FTS-only */ }
SimilarHit  = { "id": string, "name": string, "type": string, "summary": string,
                "updated_at": string, "distance": number /* cosine distance, lower = closer */ }
ContextRow  = { "rel": string, "other": string, "name": string, "type": string, "summary": string }
ReachableRow= { "depth": number, "other": string, "name": string, "type": string, "summary": string }
DriftRow    = { "obs_id": string, "entity_id": string, "entity_name": string,
                "obs_text": string, "obs_at": string, "entity_updated": string }
MediaRow    = { "id": string /* uuid7 */, "entity_id": string,
                "kind": "image" | "audio", "mime": string,
                "path": string /* content-addressed asset path under <db dir>/assets/; filename is the sha256 hex */,
                "sha256": string, "bytes": number,
                "caption": string /* stored (redacted) caption, or "" */,
                "scanned": 0 /* always 0 — the regex secret gate covers text only; media BYTES are never scanned */,
                "source": string /* stored (redacted) source label */,
                "at": string /* UTC, millisecond precision */ }
AttachResult= { "status": "attached" | "media-native" | "already-attached",
                "entity_id": string, "media_id": string,
                "kind": "image" | "audio", "mime": string,
                "path": string, "sha256": string, "bytes": number,
                "redacted": number /* secrets the text gate redacted from the candidate caption/source/name; on "already-attached" the candidate is discarded, so this refers to it, not to stored data */,
                "bytes_scanned": false /* always false — see MediaRow.scanned */,
                "embed_deferred": boolean /* media vector not stored (provider unavailable) — the row committed; vector lands on a later touch */ }
```

## Per-command `--json` shapes

| Command | Shape |
|---|---|
| `init` | `{"status": "initialized", "db": string}` |
| `upsert` | `Entity` — plus two optional additive keys when the post-commit embedding refresh failed: `"embedding": "deferred"` and `"embedding_error": string` (see note below) |
| `observe` | `{"status": "observed", "id": string, "text": string /* the STORED (redacted) text */, "redacted": number /* secrets redacted by the gate */}` — plus the same two optional `embedding` keys when the refresh failed |
| `attach` | `AttachResult` — `status` is `"media-native"` (a media-native `type=media` entity was auto-created; the entity id is `media-<sha256[:12]>` when `--id` is omitted, so re-attaching the same bytes is idempotent), `"attached"`, or `"already-attached"` (identical bytes already on this entity — nothing stored). `redacted` is the count of secrets the text gate redacted from the candidate caption/source/name; on `already-attached` the candidate is discarded and `redacted` refers to it, not to stored data (the stored caption is unchanged) |
| `relate` | `{"status": "related", "src": string, "rel": string, "dst": string}` |
| `search` | `SearchHit[]` (hybrid or, with `--regex`, FTS-regex hits with `score: 0`) |
| `context` | `{"entity": Entity, "outgoing": ContextRow[], "incoming": ContextRow[], "observations": ObsRow[], "attachments": MediaRow[], "history"?: HistoryRow[]}` — `attachments` is additive-optional (listed newest-first; bytes never secret-scanned, `scanned: 0`); observations always newest-first; with `--depth > 1` the neighbors become `ReachableRow[]` and `"depth": number` is added; `history` appears only with `--history`; `--hide-superseded` filters superseded observations out of the array |
| `prune-history` | `{"status": "pruned" \| "dry-run", "keep": number, "before": string, "versions": number}` |
| `similar` | `SimilarHit[]` — with `--media <file>`, the query vector is computed from image/audio bytes via the configured multimodal provider; refuses when the stored text embeddings were built with a different dimension (the store and the media query must share one space) — see `reembed` |
| `list` | `Entity[]` |
| `drift` | `DriftRow[]`, or `{"status": "no-drift", "count": 0}` when empty |
| `import-okf` | `{"status": "imported", "entities": number, "links": number}` (`--bundle` selects the bundle root, default `docs`) |
| `import-openwiki` | `{"status": "imported", "entities": number, "links": number}` (deprecated alias for `import-okf --bundle openwiki`; shape unchanged) |
| `reembed` | `{"status": "reembedded", "entities": number, "media": number, "model": string, "dim": number, "note": string}` — all-or-nothing rebuild of `embeddings_vec`/`embeddings_raw` (and `media_vec`/`media_raw` when a provider is configured) with the *currently configured* provider. Every vector is computed before the store drops — a provider outage aborts with nothing modified; the swap itself is one transaction. `entity_history` and `entities` are untouched; `content_hash` advances to match |
| `mcp` | no `--json`; stdio is JSON-RPC (MCP). Logs go to stderr, never stdout |

Text mode additionally prints, after each search/similar result table, one
ready-to-run drill-down line per hit: `→ context --id <id> --history`.

## MCP tools

The MCP equivalents return the same shapes as JSON text: `search` → `SearchHit[]`,
`get_context` → the `context` payload (now incl. `attachments`), `similar` → `SimilarHit[]`,
`upsert_entity` → `Entity`. `attach_media` takes either `file` (a host-local path —
the preferred, stdio-safe form) or `data_base64` (with `mime` required), plus optional
`id` (omit for a media-native `type=media` entity), `kind`, `caption`, `name`, and
`source`. It returns short confirmation text (`attached: ...` / `already-attached: ...`)
always ending with the `[bytes unscanned]` honesty marker — never raw input echoes;

`add_observation` / `relate` return short
confirmation text (`observed: ...`, `related: ...`) echoing the *stored*
(redacted) values — never the raw input. When the embedding provider is
unreachable but the write committed, both write tools still succeed (never an
error result — an agent retrying would duplicate the append): they log a
stderr WARN, `add_observation` appends `(embedding deferred)` to its
confirmation text, and `upsert_entity` returns the plain `Entity` (deferral
only on stderr). `attach_media` follows the same fail-soft contract — an
unreachable provider yields `(embedding deferred)` in the confirmation and a
committed row, not an error result.

## MCP resources

Two read-only resources are exposed in addition to the tools. Resource read
failures surface as MCP resource errors, not as JSON text.

| Resource | Payload |
|---|---|
| `entity://list` | `Entity[]` — same shape as `list --json` (capped at 500, newest-updated first) |
| `entity://{id}` | the shallow `get_context` payload (`entity`, `outgoing`, `incoming`, `observations`, `attachments`) — observations newest-first, same ordering pin as the tool |
