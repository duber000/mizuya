# kukicha stdlib bug report: `stdlib/db` scan layer aliases the driver's BLOB buffer — `list of byte` fields mutate after scan

## Summary

Struct fields of type `list of byte` (`[]byte`) scanned via
`db.ScanAll` / `db.ScanOne` / `db.ScanRow` end up **aliasing the
database/sql driver's byte slice** instead of owning a copy. The field's
contents then silently change when the driver reuses its buffer. This
violates database/sql's contract for `sql.Scanner` implementations —
values passed to `Scan` are only guaranteed valid until the next
row/statement — and produces data-dependent, timing-dependent silent
corruption.

## Environment

- kukicha v0.85.11, `stdlib/db`
- `github.com/ncruces/go-sqlite3` v0.35.6 +
  `github.com/ncruces/go-sqlite3-wasm/v6` v6.3.35304
  (the driver returns BLOB values as slices into reusable memory;
  every other driver that hands out non-owning slices is affected the
  same way)

## Root cause

`stdlib/db/db.go`, `nullSafeField.Scan` (used by `ScanAll`,
`ScanOne`, and `orderedFieldScanners`/`ScanRow`):

```go
src := reflect.ValueOf(value)
if src.Type().ConvertibleTo(s.target.Type()) {
    s.target.Set(src.Convert(s.target.Type()))
}
```

For a `[]byte` target and `[]byte` value this copies only the slice
header into the struct field. `database/sql` copies blob data only for
`*[]byte` / `*sql.RawBytes` destinations; when the destination is a
`sql.Scanner` (which `nullSafeField` is), the driver's value is passed
as-is and the [documented contract][1] is that the implementation must
copy it if it retains it past the call.

[1]: https://pkg.go.dev/database/sql#Scanner — "the src argument ... is
only valid until the next call to Scan ... implementations must not
retain src"

## Evidence

Found while debugging the mizuya vec1 SIGSEGV (see
`mizuya-bug-report.md` and the vec1 fix in this repo's history). The
identical query against the same database file:

```sql
SELECT vector AS vec FROM embeddings_vec WHERE entity_id = ?
```

- Scanned through the raw driver (`rows.Scan(&q)` with `q []byte`) —
  which `database/sql` copies — returned stable, correct bytes across
  repeated reads.
- Scanned through the stdlib layer
  (`db.Query(...) |> db.ScanOne of vecRow` with
  `vecRow{Vec: list of byte as "vec"}`) returned bytes that differed on
  **every read**: the first 4 bytes contained wasm-heap-pointer
  fragments (`0x00050010`, `0x00057ea0`, `0x0005d0d0`, …) — the driver
  reusing its buffer — and one read dropped an entire 4-byte component,
  shifting the vector. Reproduced with a fixed statement sequence
  (schema probe → spellfix refresh → repeated single-row reads); the
  corruption pattern was deterministic per sequence.

Downstream effect in mizuya: `similar --id` used the scanned blob as its
KNN query vector and computed distances against silently mutated data
(self-distance 0.0244 instead of 0.0000 on a 120-entity database).
mizuya now reads BLOBs from a plain table and unpacks to `float64`
immediately after scan, which narrows — but does not eliminate — the
aliasing window.

## Impact

Any `list of byte` struct field scanned through `stdlib/db` is unsafe to
hold past the next row/statement on the same connection. The corruption
is silent, content-dependent, and highly reproducible per workload,
which makes it look like a bug in the query or the storage engine (it
cost us most of a day to trace back to the scan layer).

## Suggested fix

Copy `[]byte` values in `nullSafeField.Scan` (and wherever
`orderedFieldScanners` shares the same path) before storing them:

```go
if b, ok := value.([]byte); ok {
    s.target.SetBytes(append([]byte(nil), b...))
    return nil
}
```

## Suggested regression test

Scan a BLOB column into a `list of byte` struct via `db.ScanOne`,
execute another statement on the same pool, then assert the field's
bytes are unchanged.
