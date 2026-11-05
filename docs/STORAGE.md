# mizuya storage cost model

What one entity costs on disk, and how a database grows. Modeled after
funes' `docs/storage.md`; figures are planning estimates from the schema,
not byte-exact guarantees (text sizes vary with content).

## What's on disk

A mizuya database is one SQLite file (WAL mode) with:

| Part | Holds | Grows with |
|---|---|---|
| `entities` | id, type, name, JSON `data` (summary+tags), timestamps | entities × text |
| `observations` | append-only observation rows | observations × text |
| `entity_history` | one full row snapshot per *actual* change | changes × data size |
| `relations` | edges | edges |
| `embeddings_vec` (vec1) | float32 vector per entity | entities × dim × 4 B |
| `embeddings_raw` | the same vector again (vec1 reads are write/search-only in the vendored build) | entities × dim × 4 B |
| `entities_fts` (FTS5) | token index over id/name/type/data | roughly the text corpus |
| `entity_ids_fuzzy` (spellfix1) | id vocabulary | entities |

## Per-entity model

- **Text floor**: name + summary + tags ≈ 0.2–1 KB typical; FTS5 index adds
  roughly another copy of the indexed text.
- **Vector floor**: `2 × dim × 4 B` per entity (vec1 row + raw side copy).
  With the default hash fallback (dim 64) that's 512 B; with a real model
  it dominates: nomic-embed-text (768) → 6 KB, text-embedding-3-small
  (1536) → 12 KB.
- **History**: a no-op upsert appends nothing (dedup against the latest
  logged version), so history cost is proportional to *actual changes*, not
  writes.

## Projection (text ≈ 1 KB/entity incl. FTS, history ≈ 1 change/10 writes)

| Entities | dim 64 (hash) | dim 768 | dim 1536 | + observations (10/entity, 200 B each) |
|---:|---:|---:|---:|---:|
| 10k | ~15 MB | ~70 MB | ~135 MB | +20 MB |
| 100k | ~150 MB | ~700 MB | ~1.35 GB | +200 MB |
| 1M | ~1.5 GB | ~7 GB | ~13.5 GB | +2 GB |

The embedding is the dominant term once a real provider is configured —
budget for it first. The vec1 index is `flat` (brute-force KNN, no extra
storage beyond the vectors); switching to a trained index later (see
TODO.md) trades a little accuracy for speed, not space.

## Maintenance notes

- WAL mode means a `-wal` file rides alongside the DB; it is checkpointed
  automatically and is transient.
- Deleting an entity cascades to relations, observations, history, and both
  embedding stores (triggers + ON DELETE CASCADE), so `delete` reclaims
  space after the next VACUUM — SQLite does not shrink the file on delete
  by itself. Run `VACUUM` occasionally if many deletions/scrubs happen.
- `observe`/`upsert` are gated by the fail-closed secret scanner
  (`MIZUYA_SECRET_SCAN`, default `redact`), so stored text never contains
  detected tokens — keep it on before any future export/share feature.

## History retention policy (recommended)

`entity_history` is append-only by design, so long-lived shared graphs need
a retention policy. Recommended for an aggregate that many consumers read:

```bash
mizuya prune-history --keep 20 --before 2026-08-01   # keep newest 20 per entity + anything after the date
mizuya prune-history --keep 20 --before 2026-08-01 --dry-run   # preview first
```

Semantics: the newest version per entity is **always** kept (current state
and as-of-today reads keep working); `--keep N` retains the newest N per
entity; `--before YYYY-MM-DD` additionally drops versions from before the
end of that day. This is the deliberate-deletion exception to append-only —
after pruning, `--as-of` dates older than the oldest retained version
error. Run it on a schedule (e.g. weekly) and `VACUUM` afterwards to
reclaim the file space. Rule of thumb: with ~1 KB data snapshots, 20
versions/entity costs ~20 KB/entity — cheap next to the vectors.
