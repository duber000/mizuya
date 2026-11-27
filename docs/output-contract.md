# mizuya output contract

Every command's `--json` output is a **stable contract, not a presentation** —
scripts and agents may parse it strictly. Plain (non-`--json`) output is for
humans and may change freely; the `→ ...` drill-down lines it prints are the
machine-useful part of text mode.

## Contract notes (this release)

Breaking changes relative to the previous contract — consumers pinned to the
old shapes must adjust:

- **MCP `add_observation` / `relate` now return structured JSON objects**
  instead of `observed: ...` / `related: ...` confirmation text (see the MCP
  tools section). `add_observation` returns `observation_id` — the handle to
  pass as `supersedes`.
- **MCP `attach_media` now returns the `AttachResult` JSON object** (the same
  shape as `attach --json`: `status`, `entity_id`, `media_id`, `kind`,
  `mime`, `path`, `sha256`, `bytes`, `redacted`, `bytes_scanned`,
  `embed_deferred`) instead of short confirmation text. The `[bytes unscanned]`
  honesty marker lives on as `bytes_scanned: false` (always). On
  `already-attached`, nothing was stored and `redacted` refers to the
  discarded candidate text, not to stored data.
- **`hide_superseded` now defaults to true** on both surfaces: the CLI gained
  `--show-superseded` to include them, and the MCP `hide_superseded` argument
  is optional (omit or `true` to hide; `false` to include).
- **`supersedes` / `superseded_by` serialize as `null`, not `""`,** when
  absent (ObsRow and ObsWrite).
- **All timestamps are ISO 8601 UTC** (`...T...Z`); pre-ISO rows are rewritten
  in place on first open (idempotent migration).

Additive-only changes (no consumer action needed):

- `observe --json` gains `observation_id`, `entity_id`, `source`, `at`,
  `supersedes` (its `id` key remains the entity id).
- New `ObsWrite` shape; new `search-observations` command/tool; new
  `archive`/`unarchive` commands and `archive_entity` tool; archived entities
  are hidden from every read path and refused by `get_context`.
- `upsert`/`observe` may carry `"embedding": "deferred"` /
  `"embedding_error": string` when the write committed but the provider was
  unreachable (see below).



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
  output is always newest-first — `ORDER BY at DESC, id DESC`. Superseded
  observations are **hidden by default**; pass `--show-superseded` (CLI) or
  `hide_superseded: false` (MCP) to include them (they are flagged via
  `superseded_by`). Consumers taking "the first N as most recent" can rely
  on this order.
- **Timestamps:** every `*_at` / `changed_at` stamp is ISO 8601 UTC with a
  `T` separator and an explicit `Z` suffix — second precision
  (`YYYY-MM-DDTHH:MM:SSZ`) for `entities`, `relations`, `media_raw`-style
  second-precision columns, and millisecond precision
  (`YYYY-MM-DDTHH:MM:SS.sssZ`) for `observations.at`,
  `entity_history.changed_at`, and `media.at`. `initDB` rewrites pre-ISO
  stamps (space separator, no `Z`) in place on open — idempotent, and old
  databases are upgraded transparently on first open after the upgrade.

## Shared shapes

```jsonc
Entity      = { "id": string, "type": string, "name": string,
                "data": string /* JSON-encoded object: {"summary": string, "tags": [string]} */,
                "created_at": string /* UTC ISO 8601, second precision, e.g. "2026-11-05T17:04:18Z" */,
                "updated_at": string }
ObsRow      = { "id": string /* uuid7 */, "text": string, "source": string,
                "at": string /* UTC ISO 8601, millisecond precision, e.g. "2026-11-05T17:04:18.647Z" */,
                "supersedes": string | null /* obs id this one corrects, null when none */,
                "superseded_by": string | null /* obs id that corrects this one, null when none — a non-null value means DO NOT ACT on this fact */ }
ObsWrite    = { "id": string /* uuid7 of the new observation */, "entity_id": string,
                "text": string /* the STORED (redacted) text */, "source": string /* stored, normalized label */,
                "at": string /* UTC ISO 8601, millisecond precision */,
                "supersedes": string | null, "redacted": number /* secrets the gate scrubbed */ }
HistoryRow  = { "id": string, "entity_id": string, "type": string, "name": string,
                "data": string /* JSON-encoded, same shape as Entity.data */,
                "changed_at": string /* UTC ISO 8601, millisecond precision */ }
SearchHit   = { "id": string, "type": string, "name": string, "summary": string,
                "updated_at": string, "score": number /* RRF score; 0 for regex/FTS-only */ }
SimilarHit  = { "id": string, "name": string, "type": string, "summary": string,
                "updated_at": string, "distance": number /* cosine distance, lower = closer */ }
ContextRow  = { "rel": string, "other": string, "name": string, "type": string, "summary": string }
ReachableRow= { "depth": number, "other": string, "name": string, "type": string, "summary": string }
DriftRow    = { "obs_id": string, "entity_id": string, "entity_name": string,
                "obs_text": string, "obs_at": string, "entity_updated": string }
MediaRow    = { "id": string /* uuid7 */, "entity_id": string,
                "kind": "image" | "audio" | "video", "mime": string,
                "path": string /* content-addressed asset path under <db dir>/assets/; filename is the sha256 hex */,
                "sha256": string, "bytes": number,
                "caption": string /* stored (redacted) caption, or "" */,
                "scanned": 0 /* always 0 — the regex secret gate covers text only; media BYTES are never scanned */,
                "source": string /* stored (redacted) source label */,
                "at": string /* UTC ISO 8601, millisecond precision */ }
MediaHit    = { "id": string /* media id */, "entity_id": string,
                "kind": "image" | "audio" | "video", "caption": string,
                "path": string, "at": string /* UTC ISO 8601 */,
                "distance": number /* cosine distance, lower = closer */ }
AttachResult= { "status": "attached" | "media-native" | "already-attached",
                "entity_id": string, "media_id": string,
                "kind": "image" | "audio" | "video", "mime": string,
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
| `observe` | `{"status": "observed", "id": string /* entity id */, "observation_id": string /* uuid7 of the new row */, "entity_id": string, "text": string /* the STORED (redacted) text */, "source": string /* stored, normalized label */, "at": string /* UTC ISO 8601 ms */, "supersedes": string \| null, "redacted": number /* secrets redacted by the gate */}` — plus the same two optional `embedding` keys when the refresh failed. `id` remains the entity id (unchanged); `observation_id` is the new observation's handle — pass it as `--supersedes` on a later correction |
| `attach` | `AttachResult` — `status` is `"media-native"` (a media-native `type=media` entity was auto-created; the entity id is `media-<sha256[:12]>` when `--id` is omitted, so re-attaching the same bytes is idempotent), `"attached"`, or `"already-attached"` (identical bytes already on this entity — nothing stored). `redacted` is the count of secrets the text gate redacted from the candidate caption/source/name; on `already-attached` the candidate is discarded and `redacted` refers to it, not to stored data (the stored caption is unchanged) |
| `relate` | `{"status": "related", "src": string, "rel": string, "dst": string}` |
| `search` | `SearchHit[]` (hybrid or, with `--regex`, FTS-regex hits with `score: 0`) |
| `context` | `{"entity": Entity, "outgoing": ContextRow[], "incoming": ContextRow[], "observations": ObsRow[], "attachments": MediaRow[], "history"?: HistoryRow[]}` — `attachments` is additive-optional (listed newest-first; bytes never secret-scanned, `scanned: 0`); observations always newest-first and **superseded observations are hidden by default** (`--show-superseded` includes them; `--hide-superseded=false` also works); with `--depth > 1` the neighbors become `ReachableRow[]` and `"depth": number` is added; `history` appears only with `--history`. Refuses an archived entity with an error naming `mizuya unarchive --id <id>` |
| `search-observations` | `ObsRow[]` — literal, case-insensitive substring match on observation text, newest-first; `--entity-id` narrows to one entity; `--limit` caps rows (default 10). The `%` and `_` LIKE metacharacters in the query are matched literally |
| `archive` | `{"status": "archived", "id": string}` — soft delete: the entity disappears from `list`, `search` (hybrid/regex/FTS), `similar`, `drift`, fuzzy suggestions, and context neighbor lists; `get_context`/`context` refuse it. The row, observations, relations, and history are kept; writes are still allowed; `updated_at` is not bumped and no history row is appended |
| `unarchive` | `{"status": "unarchived", "id": string}` — clears the archive flag; every read path sees the entity again |
| `prune-history` | `{"status": "pruned" \| "dry-run", "keep": number, "before": string, "versions": number}` |
| `similar` | `SimilarHit[]` — with `--media <file>`, the query vector is computed from image/audio bytes (or frame-sampled, mean-pooled video) via the configured multimodal provider; refuses when the stored text embeddings were built with a different dimension (the store and the media query must share one space) — see `reembed` |
| `list` | `Entity[]` |
| `drift` | `DriftRow[]`, or `{"status": "no-drift", "count": 0}` when empty |
| `import-okf` | `{"status": "imported", "entities": number, "links": number}` (`--bundle` selects the bundle root, default `docs`) |
| `import-openwiki` | `{"status": "imported", "entities": number, "links": number}` (deprecated alias for `import-okf --bundle openwiki`; shape unchanged) |
| `reembed` | `{"status": "reembedded", "entities": number, "media": number, "model": string, "dim": number, "note": string}` — all-or-nothing rebuild of `embeddings_vec` (and `media_vec`/`media_raw` when a provider is configured) with the *currently configured* provider. Every vector is computed before the store drops — a provider outage aborts with nothing modified; the swap itself is one transaction. `entity_history` and `entities` are untouched; `content_hash` advances to match |
| `similar-media` | `MediaHit[]` — KNN over the `media_vec` index with the query embedded via the configured multimodal provider; refuses when the query dim and the stored `media_raw` dim disagree (run `reembed` after switching providers) |
| `mcp` | no `--json`; stdio is JSON-RPC (MCP). Logs go to stderr, never stdout |

Text mode additionally prints, after each search/similar result table, one
ready-to-run drill-down line per hit: `→ context --id <id> --history`.

## MCP tools

Ten tools are registered. The read tools return the same shapes as their CLI
counterparts as JSON text: `search` → `SearchHit[]`, `get_context` → the
`context` payload (now incl. `attachments`), `similar` → `SimilarHit[]`,
`upsert_entity` → `Entity`, `search_observations` → `ObsRow[]`.

Write tools return structured JSON objects (never raw input echoes):

- `upsert_entity` → `Entity` (the stored, post-redaction entity). Tags must be
  a JSON array of strings — a tag containing a comma is rejected with a clear
  error (the CLI takes a comma-separated list; over MCP the array is the only
  grammar). When the post-commit embedding refresh fails, the tool still
  succeeds (an agent retrying on failure would duplicate the append): it logs
  a stderr WARN and returns the plain `Entity`.
- `add_observation` → `{"status": "observed", "id": string /* entity id */,
  "observation_id": string, "entity_id": string, "text": string /* STORED,
  redacted */, "source": string /* stored, normalized */, "at": string /* ISO
  8601 ms */, "supersedes": string | null, "redacted": number}` — plus
  `"embedding": "deferred"` when the write committed but the provider was
  unreachable. Pass `observation_id` as `supersedes` on a later correction.
- `relate` → `{"status": "related", "src": string, "rel": string,
  "dst": string}` — `rel` is the stored (possibly redacted) label.
- `archive_entity` → `{"status": "archived" | "unarchived", "id": string}` —
  soft delete; see the `archive` CLI row above for exact semantics.
- `attach_media` → `AttachResult` — the same object `attach --json` prints
  (see the `attach` CLI row and the paragraph below).

`attach_media` takes either `file` (a host-local path —
the preferred, stdio-safe form) or `data_base64` (with `mime` required), plus optional
`id` (omit for a media-native `type=media` entity), `kind`, `caption`, `name`, and
`source`. It returns the `AttachResult` JSON object (see the `attach` CLI row
above — identical shape, including `bytes_scanned: false` as the permanent
"bytes never secret-scanned" honesty marker; never raw input echoes);
`similar_media` takes the same `file` / `data_base64` (+ `mime`) query pair, accepts a
`kind` filter and `limit`, and returns `MediaHit[]` as JSON text (same `dist` guard as
`similar --media`: query dim must match the stored index dim).

`search_observations {text, entity_id?, limit?}` finds observations by literal,
case-insensitive substring (`%`/`_` are matched literally), newest-first — the
lookup that yields the `observation_id` to pass as `supersedes`.

`get_context` observations are newest-first; **superseded observations are
hidden by default** — pass `hide_superseded: false` to include them (flagged
via `superseded_by`). `get_context` refuses an archived entity (and so does
the `entity://{id}` resource). `source` labels are normalized to lowercase
with surrounding whitespace stripped on write (conventional vocabulary:
`user`, `session`, `retro`, `conversation` — not enforced). `similar`'s
`threshold` is an integer 1–100: return every stored entity whose cosine
distance falls within the closest N percentile of all distances after
filters (100 = every stored entity; unset/0 = use `limit`, default 5); it
overrides `limit` when set; values outside [1, 100] are rejected.

## MCP resources

Two read-only resources are exposed in addition to the tools. Resource read
failures surface as MCP resource errors, not as JSON text.

| Resource | Payload |
|---|---|
| `entity://list` | `Entity[]` — same shape as `list --json` (capped at 500, newest-updated first; archived entities are excluded) |
| `entity://{id}` | the shallow `get_context` payload (`entity`, `outgoing`, `incoming`, `observations`, `attachments`) — observations newest-first, superseded hidden; refuses archived entities (unarchive first) |
