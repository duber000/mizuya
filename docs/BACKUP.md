# Backing up and restoring mizuya

mizuya ships two subcommands for backups. `mizuya snapshot` produces a
single, self-contained archive of a live database; `mizuya verify` checks
that an archive is intact and restorable. Encryption, upload, retention
and scheduling are deliberately **not** part of mizuya — they are ops
policy and live elsewhere (on this machine: `cmd/mizuya-backup` in
`kukicha.org/infra`, which encrypts with age, uploads to a dedicated R2
bucket with a 90-day lifecycle, writes a sha256 manifest, and runs from a
user systemd timer).

## Why this lives in the mizuya binary

Only the mizuya binary can open its own database correctly: `vec1`
(embeddings), `spellfix1` (fuzzy ids) and FTS5 are loaded by mizuya, not
by the system sqlite. A backup nobody can validate is a hope, not a
backup — so the verify step runs with the same extensions the live
database uses.

## Snapshot

```console
$ mizuya snapshot --out /path/to/mizuya-snapshot-20261127.tar.gz
<sha256>  /path/to/mizuya-snapshot-20261127.tar.gz
```

- The database is copied with `VACUUM INTO` through mizuya's own
  connection pool. That is online and consistent: no service stop, no
  `-wal`/`-shm` side files to copy, and the copy is compacted for free.
  The live database is never modified.
- If `<db dir>/assets/` exists (media bytes, sha256-addressed), it rides
  in the same archive next to the snapshot. Media rows reference those
  files by path, so both must restore together or attachments break.
- The archive contains `mizuya.db` at its root plus `assets/...`. It is
  written to a temp file in the destination directory and renamed into
  place — a failed run never leaves a partial archive behind.
- `--out` is required and must end in `.tar.gz` (or `.tgz`). The
  destination must not already exist; the archive is created mode 0600
  (it is a copy of private memory data). The printed line is
  sha256sum-compatible — `mizuya snapshot --out x.tar.gz | sha256sum -c`
  works. `--json` prints `{"path","sha256","bytes"}` instead.
- vec1 `flat` index: there are no separate index files to capture;
  vectors are rows. `media_raw` lives in the database; `assets/` bytes
  live outside it — the archive carries both.

## Verify

```console
$ mizuya verify /path/to/mizuya-snapshot-20261127.tar.gz
verify ok /path/to/mizuya-snapshot-20261127.tar.gz
  entities:       42
  observations:   310
  relations:      87
  embeddings_vec: 42
```

Verify unpacks the archive to a temp dir (refusing members with absolute
paths or `..` segments, with a 10 GiB uncompressed cap), opens the
snapshot **read-only** with mizuya's extension set — it does not run
`initDB`, so the snapshot is reported as it is, never migrated — and
checks:

1. `PRAGMA integrity_check` — structural corruption fails here.
2. Sanity counts (entities, observations, relations, embeddings_vec),
   printed for the operator. A backup that restores to an empty database
   is not a backup: zero entities fails verify.
3. The vec tables are queryable (one `LIMIT 1` probe per vec table), so a
   corrupt or missing vector index fails at verify time, not at the first
   `similar` query after a restore.

Any failure exits non-zero with a clear message. `--json` prints the
counts as an object. Verify does not check the archive against a sha256
manifest — that is the uploader's job (it wrote the manifest).

## Restore

Restore = put the archive's contents back over `~/.mizuya/` while the
server is stopped, then start it again:

```console
$ systemctl --user stop mizuya-mcp.service
$ cp ~/.mizuya/mizuya.db ~/.mizuya/mizuya.db.pre-restore   # belt and braces
$ tar -xzf /path/to/mizuya-snapshot-20261127.tar.gz -C ~/.mizuya/
$ systemctl --user start mizuya-mcp.service
```

(If the archive came from an encrypted store, decrypt it first; the
decryption key is the infra side's concern, not mizuya's.)

On open, `initDB` migrates the schema forward (idempotent
`CREATE IF NOT EXISTS` + guarded migrations), so an older snapshot simply
catches up to the current schema. This is also the upgrade mechanism:
**back up before upgrading mizuya**, then restore-and-open if the new
version turns out to be incompatible with your data.

After a restore, run `mizuya verify` on the archive you restored from if
you have not already — and spot-check with `mizuya list` and
`mizuya context --id <something you know>`.

## Suggested cadence

The live database is small (a few hundred KB for typical use; media bytes
dominate when attachments are in play), so snapshot cost is noise. Take
one before every upgrade and on whatever schedule your infra timer uses;
keep at least one copy off-machine. `verify` before upload is cheap and
catches both corrupt archives and empty snapshots.
