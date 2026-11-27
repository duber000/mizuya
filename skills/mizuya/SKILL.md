---
name: mizuya
description: 'Persistent memory for AI agents: a SQLite-backed knowledge graph (FTS5 + cosine-vector search) for entities, typed relations, and append-only observations. Use it to remember projects, tools, people, concepts and their connections across sessions. Access via MCP (mizuya mcp) with 10 tools: upsert_entity, add_observation (returns observation_id; pass supersedes to correct), relate, search, search_observations, get_context, similar, attach_media, similar_media, archive_entity — or the CLI (mizuya <subcommand>). Conventions: observations are append-only — correct with supersedes; superseded observations are hidden by default (hide_superseded: false to include). Free text passes a fail-closed secret gate (redacted in place; echoes are post-redaction). Deletion is soft (archive_entity): archived entities are invisible to reads and get_context refuses them. Tags over MCP are a JSON array of strings; the CLI takes comma-separated tags. source labels are normalized to lowercase. Timestamps are ISO 8601 UTC.'
metadata:
    okf_generated_at: "2026-11-27T16:33:25Z"
    okf_generated_by: kukicha-pack/0.86.12
    okf_source: .
    okf_stale_after: "2027-02-27T16:33:25Z"
    okf_status: draft
    version: 0.5.0
---

# Mizuya

Persistent memory for AI agents: a SQLite-backed knowledge graph (FTS5 + cosine-vector search) for entities, typed relations, and append-only observations. Use it to remember projects, tools, people, concepts and their connections across sessions. Access via MCP (mizuya mcp) with 10 tools: upsert_entity, add_observation (returns observation_id; pass supersedes to correct), relate, search, search_observations, get_context, similar, attach_media, similar_media, archive_entity — or the CLI (mizuya <subcommand>). Conventions: observations are append-only — correct with supersedes; superseded observations are hidden by default (hide_superseded: false to include). Free text passes a fail-closed secret gate (redacted in place; echoes are post-redaction). Deletion is soft (archive_entity): archived entities are invisible to reads and get_context refuses them. Tags over MCP are a JSON array of strings; the CLI takes comma-separated tags. source labels are normalized to lowercase. Timestamps are ISO 8601 UTC.

## Usage

Run this skill with:

```bash
kukicha run scripts/mizuya/ [args]
```

## Exposed functions

- **NewRegexScanner**() → RegexScanner
