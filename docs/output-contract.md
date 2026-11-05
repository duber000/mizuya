# mizuya output contract

Every command's `--json` output is a **stable contract, not a presentation** —
scripts and agents may parse it strictly. Plain (non-`--json`) output is for
humans and may change freely; the `→ ...` drill-down lines it prints are the
machine-useful part of text mode.

Stability rules:

- Field names and types below are frozen. New *optional* fields may be added
  (additive-only); nothing is renamed or removed without a major version bump.
- Errors in `--json` mode print as `{"error": "<message>"}` with exit code 1.
- Drill-down coordinate: any search/similar hit's `id` is the stable handle —
  `mizuya context --id <id> --json` (CLI) or the MCP `get_context` tool with
  `id: <hit.id>` returns its observations (each with its own `id`) and,
  with `--history` / `history: true`, its append-only version log.

## Shared shapes

```jsonc
Entity      = { "id": string, "type": string, "name": string,
                "data": string /* JSON-encoded object: {"summary": string, "tags": [string]} */,
                "created_at": string /* UTC "YYYY-MM-DD HH:MM:SS" */,
                "updated_at": string }
ObsRow      = { "id": string /* uuid7 */, "text": string, "source": string,
                "at": string /* UTC, millisecond precision */, "supersedes": string /* obs id or "" */ }
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
```

## Per-command `--json` shapes

| Command | Shape |
|---|---|
| `init` | `{"status": "initialized", "db": string}` |
| `upsert` | `Entity` |
| `observe` | `{"status": "observed", "id": string, "text": string, "redacted": number /* secrets redacted by the gate */}` |
| `relate` | `{"status": "related", "src": string, "rel": string, "dst": string}` |
| `search` | `SearchHit[]` (hybrid or, with `--regex`, FTS-regex hits with `score: 0`) |
| `context` | `{"entity": Entity, "outgoing": ContextRow[], "incoming": ContextRow[], "observations": ObsRow[], "history"?: HistoryRow[]}` — with `--depth > 1` the neighbors become `ReachableRow[]` and `"depth": number` is added; `history` appears only with `--history` |
| `similar` | `SimilarHit[]` |
| `list` | `Entity[]` |
| `drift` | `DriftRow[]`, or `{"status": "no-drift", "count": 0}` when empty |
| `import-openwiki` | `{"status": "imported", "entities": number, "links": number}` |
| `distill` | `{"status": "no-candidates"}` or `{"status": "dry-run", "candidates": number, "observations": number, "prompt": string}` or `{"status": "distilled", "candidates": number, "observations": number, "output": string}` |
| `mcp` | no `--json`; stdio is JSON-RPC (MCP). Logs go to stderr, never stdout |

Text mode additionally prints, after each search/similar result table, one
ready-to-run drill-down line per hit: `→ context --id <id> --history`.

## MCP tools

The MCP equivalents return the same shapes as JSON text: `search` → `SearchHit[]`,
`get_context` → the `context` payload, `similar` → `SimilarHit[]`,
`upsert_entity` → `Entity`. `add_observation` / `relate` return short
confirmation text (`observed: ...`, `related: ...`).
