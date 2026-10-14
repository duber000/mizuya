# kukicha stdlib bug report: `sqlite.OpenWithExtensions` with an empty pragma map silently drops `Open`'s defaults (no WAL)

## Summary

`stdlib/sqlite.OpenWithExtensions`'s doc comment says:

> Pass an empty pragmas map for the Open defaults

but `OpenWith` builds the DSN **only** from the provided map. An empty map
produces a connection with no pragmas at all — `journal_mode` stays
SQLite's default rollback journal (`delete`) instead of `Open`'s WAL.
Any caller following the documented advice (mizuya's `openPool`,
`doInit`, and MCP server pool all did) silently loses the WAL default.

## Environment

- kukicha v0.85.11, `stdlib/sqlite`
- `github.com/ncruces/go-sqlite3` driver v0.35.6
  (`github.com/ncruces/go-sqlite3-wasm/v6` v6.3.35304)

## Measured behavior

`sqlite.Pragma` on the same database file, kukicha v0.85.11:

| Pool | journal_mode | foreign_keys | busy_timeout |
|---|---|---|---|
| `sqlite.Open(path)` | `wal` | `1` | `5000` |
| `sqlite.OpenWithExtensions(path, {}, …)` | **`delete`** | `1` | `60000` |

Reproducer:

```kukicha
import "stdlib/db"
import "stdlib/sqlite"
import "github.com/ncruces/go-sqlite3/ext/vec1" as vec1ext

func main()
    p := sqlite.OpenWithExtensions("/tmp/probe.db", empty map of string to string, vec1ext.Register) onerr panic "{error}"
    defer db.Close(p)
    jm := sqlite.Pragma(p, "journal_mode") onerr panic "{error}"
    print("journal_mode={jm}")    # prints "delete", expected "wal"
```

## Scope notes (what is and isn't lost)

Two of `Open`'s three documented defaults are accidentally preserved —
not by the stdlib but by the ncruces driver itself, which applies
`foreign_keys(ON)` and `busy_timeout(60000)` to every connection it
opens. That masking is why this went unnoticed:

- `foreign_keys(ON)` **is** enforced under `OpenWithExtensions(∅)` (FK
  constraint violations reproduce), so `ON DELETE CASCADE` still fires —
  via the driver, not the stdlib.
- `busy_timeout` is `60000` under `OpenWithExtensions(∅)` (the driver
  default), which happens to exceed `Open`'s `5000`.

The genuinely lost default is `journal_mode(WAL)`: databases opened this
way run in rollback-journal mode, forgoing WAL's concurrent-reader
support and crash-resilience — for a long-lived MCP server plus
out-of-band CLI invocations against the same file, that is the common
and intended deployment.

## Root cause

`stdlib/sqlite/sqlite.go`, `OpenWith`:

```go
parts := make([]string, 0, len(pragmas))
for k, v := range pragmas {
    ...
    parts = append(parts, fmt.Sprintf("_pragma=%v(%v)", k, v))
}
connStr := buildURI(path)
if len(parts) != 0 {
    ...
    connStr = connStr + sep + strpkg.Join(parts, "&")
}
return db.Open("sqlite3", connStr)
```

With `len(pragmas) == 0` there is no fallback to `Open`'s default pragma
set (`_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)&_pragma=busy_timeout(5000)`),
and `OpenWithExtensions` (the only way to register ncruces extension
registrars pool-wide) routes through it.

## Suggested fix

Either:

1. `OpenWith` falls back to `Open`'s default pragma set for keys absent
   from the caller's map (empty map ⇒ exactly `Open`'s behavior, matching
   the doc comment), **or**
2. if the current behavior is intended, fix the doc comments on
   `OpenWith`/`OpenWithExtensions` to say an empty map applies **no**
   pragmas, and document that the underlying driver still enforces
   `foreign_keys` and a 60 s busy timeout.

Option 1 is what callers reading the current doc comment already believe
they are getting.

## Workaround

Pass the pragmas explicitly at every call site:

```kukicha
sqlite.OpenWithExtensions(path, map of string to string{"journal_mode": "WAL"}, vec1ext.Register)
```

mizuya carries this workaround locally (see the companion commit);
`foreign_keys`/`busy_timeout` were left to the driver's defaults, which
already match or exceed `Open`'s.
