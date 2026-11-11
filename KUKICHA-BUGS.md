# KUKICHA-BUGS.md — Kukicha sharp edges, with repros

Field notes from building and reviewing `mizuya` against **kukicha v0.86.9**
(vendored stdlib `0.86.9+e2533b4f`, git tag `kukicha-v0.86.9`). This is the
write-up AGENTS.md's "Kukicha gotchas (2026-11-05, kukicha v0.86.4)" section
always pointed at (`/tmp/KUKICHA_BUGS.md` is gone; this file is its durable
replacement). Rule: every entry below is something that either actually broke
in this repo, or is documented compiler/stdlib behavior with a sharp edge a
Go developer would not predict. Verify entries against `.kukicha/stdlib/` and
`.agents/skills/kukicha/SKILL.md` — both are compiler-owned and regenerated.

**Verification status on v0.86.9** (re-checked 2026-11-11, not just transcribed
from the v0.86.4-era notes — see §6 for the exact probes):

| v0.86.4-era observation | v0.86.9 | How verified |
|---|---|---|
| §3.10 `kukicha test` flag forwarding (`-benchtime 200x` → `FAIL 200x`) | **Fixed** | Ran the exact 2026-11-05 repro: 200 bench iterations, `ok` |
| §1.3 sibling `*_test.kuki` visibility (`semantic/undefined`) | **Fixed** | Scratch package: `kukicha check` passes with a cross-file helper |
| §1.2 `sort.By*` returns a copy | **Still present** | Vendored `stdlib/sort/sort.go` wraps every sorter in `slices.Clone` |
| §2.1 `test.AssertEqual` `reflect.DeepEqual` int64-vs-int | **Still present** | Reproduced: probe test fails `expected 1, got 1 (same value, different numeric kind — want int, got int64)` |
| §2.2 `regex.MustCompile` rejects non-literals (security lint) | **Still present** | Reproduced: `[security/regex-panic]` error at `check` time |
| §2.4 `env.Set`/`env.Unset` return errors | **Still present** | Vendored `stdlib/env/env.go` (returns `error`) |

Note: AGENTS.md's "observed 2026-11-05 (v0.86.4)" heading predates the
v0.86.9 migration; the section there now carries per-gotcha status markers
mirroring this table.

Severity key: **Bug** = wrong behavior, cost a debug cycle · **Footgun** =
works as designed, will silently bite · **Papercut** = friction, fails loud ·
**Process** = repo/build/CI hygiene · **Design** = sharp edge, but principled.

---

## 1. Syntax

### 1.1 `//` is a lexer error, not a comment (Papercut)

Kukicha comments start with `#`. `//` is lexed as two division operators and
is a hard lexer error; `kukicha fmt` refuses to run on the file. Real
diagnostic from this repo (`mcp_server.kuki:86`):

```text
── ERROR ───── /var/home/tluker/repos/kukicha/mizuya/mcp_server.kuki:86:9 ──
[syntax/double-slash-comment] // is not a comment in Kukicha
hint: use # for comments (// lexes as two division operators)
```

```text
kukicha fmt: error checking mcp_server.kuki: lexer error:
lexer errors: [mcp_server.kuki:86:9: // is not a comment in Kukicha]
```

Two positives: the lexer consumes the rest of the line so the contents never
cascade into further errors, and the diagnostic carries a `#` quickfix.
Expect every Go developer to hit this within the first file. The reverse is
not true: Go's `//` comments are the only rejected C-style comment syntax;
there is no `/* */` form either. Intended, documented, still the #1 papercut.

**Mitigation:** the lexer error fires at `check`/`fmt` time — you cannot
commit unknowingly if you run the toolchain. CI gate would make this free (§4.1).

### 1.2 `sort.ByKey*` / `sort.By` return a copy, they do not sort in place (Bug)

`sort.ByKey(f)`, `sort.ByKeyDesc(f)`, `sort.By(f)` evaluate to a **new,
sorted list**. Discarding the result is a valid expression statement that
keeps the original (map) iteration order. **Verified still present on
v0.86.9** (2026-11-11): every sorter in the vendored `stdlib/sort/sort.go`
is wrapped in `slices.Clone` — the returned-copy semantics are by design.
This is exactly how the hybrid search RRF top-k cut became nondeterministic
map order in `hybridSearch` — caught only by `TestLabeledRecall` flapping:

```kukicha
# wrong: discards the sorted copy; ids stay in random map order
sort.ByKeyDesc(id => scores[id])
# right — bind the result:
ids := maps.Keys(scores) |> sort.ByKeyDesc(id => scores[id])
```

See `hybrid.kuki`, TODO.md "Tested and abandoned", AGENTS.md gotcha 3.

**Mitigation:** bind every sort call (`best := xs |> sort.ByKeyDesc(f)`). A
`semantic/*` lint for discarded `sort.*` results would catch this class —
nothing does today. A labeled benchmark caught this and the RRF-scores copy
fix; two of the repo's own bugs were found by benchmarks, not by reading.

### 1.3 A `*_test.kuki` cannot see helpers from a sibling `*_test.kuki` (Footgun — FIXED on v0.86.9, verified)

`kukicha check` evaluates each test file in isolation, per the v0.86.4-era
observation: `semantic/undefined` at check time for helpers declared in
another `*_test.kuki`, even though `go test` compiles the transpiled files
together. **Verified fixed on v0.86.9** (2026-11-11): a scratch package with
`a_test.kuki` defining a helper and `b_test.kuki` calling it passes
kukicha check. The v0.86.4-era workaround is gone from this repo: the
pool helpers were consolidated into `testutil_test.kuki` (2026-11-11) and
`store_test`/`phase3_test`/`bench_test` all share them.

### 1.4 `enum String()` returns the case name, not the wire value (Footgun)

Generated by the compiler, e.g. for:

```kukicha
enum EntityType
    Project = "project"
```

```go
func (e EntityType) String() string {
	switch e {
	case EntityTypeProject:
		return "Project"
	...
	}
}
```

The JSON-tagged enum values are `project`, `tool`, ... but `String()` returns
`"Project"`, `"Tool"`. The `: string` annotation only changes `String()` to
return the raw value; the un-annotated form returns the **case name**. The
repo's flag help and MCP tool schemas therefore advertised
`Project, Tool, Person, ...` (unusable as `--type` values) until
`validEntityTypes()` was changed to `strpkg.ToLower(t.String())`. Nothing
warns — the natural `t.String()` is silently wrong for display purposes;
a wrong `"Project"` echoed to users or tools is a closed-set mismatch.

Related: declared values are not round-tripped through `String()` either —
`AllEntityType()` + `String()` + `ToLower()` is the only reliable route to
the wire list. See `main.kuki:validEntityTypes`.

### 1.5 Interpolation `{` rules and `'` vs `"` strings (Footgun, documented)

- `\{` and `\}` for literal braces inside `"..."`; single-quoted `'...'`
  strings are never interpolating (ideal for regex and static JSON);
  backticks are raw multiline interpolating `${...}`.
- A `{` in a `"..."` string opens interpolation whenever a matching `}`
  appears — except top-level commas (regex quantifiers like `{2,3}` keep the
  text literal).
- Go's `ReplaceAllString`-style templates (`${1}`, `$1`) collide with
  `"{...}"` interpolation: `"${1}"` in a cooked string is eaten as
  kukicha interpolation, and `$1` + word characters is parsed by Go as a
  *named* group. Spell replacement templates in `'...'` (e.g.
  `sc.pattern.Replace(out, "[REDACTED:{d.name}]")` happens to interpolate
  `{d.name}` correctly; anything with `$\{1\}` needs escapes or single quotes).
- `knnArg := "\{k: {k}\}"` in `search.kuki` is exactly the `\\{` brace-literal
  case — expect one of these per codebase.

See SKILL.md "Strings and Interpolation" for the full grammar; it is correct
and subtle, so budget for the first-time write.

### 1.6 Multi-value + `onerr` postfix — uncharted territory (Footgun)

`onerr` postfix binds the **statement**, not individual results, and the
skill only sanctions it cleanly for functions whose last return value is
`error`:

> "the enclosing function must return `error` as its last value, or be void
> (where the error is dropped) — other shapes take an explicit handler
> (`semantic/onerr-invalid`)"

No precedent exists in this repo or the vendored stdlib for
`a, b := f() onerr <handler>` with two value slots or a wrap-style handler,
and it's not obvious which shapes compile. Noting here so the next person
doesn't have to discover it the hard way (I hit it and rewrote to the
explicit two-line form): no `onerr` with multi-value calls, ever —
`x, e := f(); if e isnt empty ...` is the portable idiom.

### 1.7 `for i from 0 to n` is upward-only for runtime `n` (Footgun, documented)

`for i from 0 to n` lowers to Go's range-over-int — for a runtime-negative
`n` it runs **zero iterations**, silently. Descending runtime bounds need
`for i from n through 0` (or a non-zero start). `to` vs `through` (`<` vs
`<=`) and this asymmetry are easy to mistake for Python. See
SKILL.md "Control Flow" / `concept/numeric-loops`.

### 1.8 Muscle memory items (Papercut)

- `i = i + 1`, never `i += 1` (`syntax/compound-assign`, except `&=`); the
  compiler folds it back into `+=` for free. `i++`/`i--` are fine.
- No `while` — a bare `for cond` is that loop.
- `equals` / `isnt` replace every `==` / `!=`; ordering operators stay
  symbolic.
- `in` / `not in` are membership operators (lists, maps by key, strings by
  substring) **and** still drive `for` — non-comparable element lists need
  `slice.Contains`.

## 2. Stdlib semantics

### 2.1 `test.AssertEqual` uses `reflect.DeepEqual` — int64 vs int (Papercut, still present on v0.86.9)

`db.Count` / rows-affected style results come back `int64`;
`test.AssertEqual(t, count, 4)` fails even when numerically equal.
**Verified still present on v0.86.9** (2026-11-11): a scratch test asserting
`db.Count` equals `1` fails with

```text
expected 1, got 1 (same value, different numeric kind — want int, got int64)
```

Every test in this repo casts: `test.AssertEqual(t, relCount as int, 2)`.
AGENTS.md gotcha 4. Free at runtime, annoying everywhere; a future
`AssertEqualInt64`/`AssertLenEqual` would kill ~20 casts.

### 2.2 `regex.MustCompile` rejects non-literal patterns (Footgun, lint is right, still present on v0.86.9)

The security linter requires a literal pattern argument to `MustCompile` —
anything data-driven must go through `regex.Compile` (which returns an
error; `onerr` it) or `regex.MatchSafe`. **Verified still present on
v0.86.9** (2026-11-11, `[security/regex-panic]`):

```text
[security/regex-panic] regex panic risk: regex.MustCompile with non-literal
pattern — regexp.MustCompile panics on invalid input.
hint: use regex.MatchSafe(pattern, text) for one-shot matching with runtime
patterns, or regex.Compile(pattern) — it returns (Pattern, error).
```

The diagnostic is precise and it's the correct design (MustCompile would
panic on bad user input), but the failure mode is "nitpick at check time,"
and the fix is always the same two lines. AGENTS.md gotcha 4.

### 2.3 `sqlite.OpenWithExtensions` is process-global and append-only (Footgun)

From `.kukicha/stdlib/sqlite/sqlite.go` (verbatim):

> Scope caveat (inherited from ncruces AutoExtension): registration is
> process-global and append-only. Every connection the driver opens from
> then on — including connections in other pools — runs the registrar.
> Registering the same registrar twice makes it fire twice per connection
> and trips "function already registered" errors, so treat registration as
> one-shot at process start.

Consequences this repo lives with:

- There is **no per-command / per-connection extension** — you cannot load
  `fileio`/`blobio` only inside a hypothetical import command's connection;
  every pool (test pools included) gets the global set.
- Opening many pools per process (the test suite does) relies on ncruces
  deduping registrar callbacks — treat each registration as once-per-process.
- `initDB` runs on every open by design; spelling extensions in a shared
  `OpenWithExtensions(...)` call is the only safe pattern.

### 2.4 `env.Set` / `env.Unset` return errors (Papercut, still present on v0.86.9)

Every env-var manipulation in tests needs `onerr discard` — there's no
void variant and none is promised; **verified in the vendored v0.86.9
stdlib source** (`env.go`: `func Set(key string, value string) error`,
`func Unset(key string) error`). AGENTS.md gotcha 4. Fine as a design
(env mutation *is* fallible), but the noise is real.

### 2.5 `json` unexported fields fail loud — good edge (credit where due)

A lowercase struct field without an `as` tag is skipped by Go's reflection
encoders, and `semantic/json-unexported-fields` warns at every JSON
(de)serialization site touching it — so the drop fails at **check** time,
not silently on the wire. `models.kuki` tags every serialized field
(`Id: string as "id"` etc.). This is the model for everything else in this
file: invisible to a skim, loud to a check run.

### 2.6 Things that work exactly as documented

- `cli`: the exit-code contract is real — parse failures `{"error": ...}`
  exit 2, `UsageFail` marker (marked *experimental* in the stdlib, but it is
  the in-handler usage lane and works) exit 2, handler errors exit 1, and
  usage failures print `usage error:`/`error:` appropriately; JSON mode
  prints `{"error": ...}` on stdout. All verified live against the binary.
- `log` defaults to stderr (MCP's stdout stays pure JSON-RPC — verified:
  6 tools over stdio, zero stray lines).
- `many args: T` spread syntax, `db.Transaction`, `db.Query |> db.ScanAll of T`.
- `check --strict` (advisory lints promoted to errors) is clean on this
  tree; `fmt --check --json` emits a machine-readable offender list.
- `kukicha test` transpiles `*_test.kuki` in place, then runs `go test` —
  unrecognized flags forward to `go test` verbatim.

## 3. Tooling / build / CI

### 3.1 No CI gate for `check` / `fmt` / `test` (Process, high)

`.github/workflows/docker.yml` only builds and pushes the image on tag /
main pushes. Nothing runs the verification trio from AGENTS.md. This
incident log (this session) is the payoff:

- a `//` lexer error commit candidate (caught by manual check)
- an unformatted `phase3_test.kuki` (caught by `fmt --check --json .`)
- a compiler version skew Dockerfile v0.86.5 vs vendored stdlib v0.86.9
- a brewed `main.go` needing manual deletion after builds (twice)

Fix is ~15 lines in the workflow: `kukicha check ./...`,
`kukicha fmt --check --json .`, `kukicha test . -count=1` on PRs and main.
`fmt --check --json` output is already CI-shaped.

### 3.2 Compiler/stdlib skew is invisible (Process)

Repo history says v0.86.9 (vendored stdlib, tag `kukicha-v0.86.9`); the
Dockerfile installed `kukicha@v0.86.5`; AGENTS.md said v0.86.9; no tool
reconciles them. The failure mode is source-level syntax/check divergence
inside the image, discovered at tag time. Fix: pin the Dockerfile to the
same version AGENTS.md names, and reference one of them from the other.
(Fixed in this repo — Dockerfile now `v0.86.9`.)

### 3.3 Generated artifacts land in the package root (Process)

`kukicha build` writes `main.go` next to the source (documented), and
`kukicha test` re-transpiles in place when it sees stale artifacts
("main.go was older than a .kuki source — re-transpiled before testing").
`.gitignore` covers both (`main.go`, `*.go`), but the discipline is all
manual — this repo has deleted brewed `main.go` twice in one session.
Consequences if it slips: brewed Go in a PR (AGENTS.md forbids), and the
invisible overwrite question for same-stem hand-written `.go` (compiler
refuses to overwrite files without the generated header — good guard, but
it's the *second* line of defense, not this one).

### 3.4 `kukicha test` re-transpiles silently; `go test` can test stale code (Process)

Because `kukicha test` refreshes stale artifacts in place, `go test ./...`
executes **whatever `*.go` happen to sit at the root** — it does not call
the compiler, does not know it is stale, and passes happily. Any CI built
on bare `go test` skips every Kukicha diagnostic. Correct gate:
`kukicha test . -count=1` only. (`AGENTS.md`'s "`go test ./...` also works
on the transpiled artifacts" is accurate only after `kukicha test` is run.)

### 3.5 `kukicha build` defaults to `GOAMD64=v3` (AVX2, Haswell-2013+) (Process)

No build-time warning is emitted; the published ghcr image will **SIGILL
on pre-Haswell CPUs** and some older cloud VMs. For a tool agents may run on
whatever host they live on, that's a bad default to carry silently. Fix:
`GOAMD64=v2` in the Dockerfile (or a documented `GOAMD64` requirement in
the release notes). `kukicha brew` takes the same flag and inherits the
same default.

### 3.6 `.kukicha/run/` accumulates stale transpilation (Papercut)

`kukicha run` / `check` write hashed artifacts under `.kukicha/run/`;
three stale sets sat in this tree during review. All gitignored; none
pruned automatically; cosmetic.

### 3.7 `.dockerignore` misses root-level `*.go` (Papercut)

`.gitignore` excludes brewed `*.go`; `.dockerignore` excludes only `.git`,
`main.go`, `README.md`, `AGENTS.md` — so local brewed artifacts (`bench_test.go`,
`store_test.go`, ...) enter the Docker build context and sit beside the
real build. Harmless for `go build` (ignores `_test.go`), but it bloats the
context and can mask stale-brewed-file confusion. Adding `*.go` is one line.

### 3.8 AGENTS.md pointed at a `/tmp/` path (Papercut, fixed)

`AGENTS.md` referenced `/tmp/KUKICHA_BUGS.md` — nonexistent by design (tmp
files evaporate); the gotcha list survived but the repros were lost. This
file replaces it and AGENTS.md points here. (Editorial: when a doc says
"full write-up elsewhere," put the elsewhere in-tree.)

### 3.9 `kukicha fmt --check` is all-or-nothing per file (Design, credit where due)

`fmt` accepts or rejects whole files, not hunks; combined with the
machine-readable `--json` offender list, that makes the gate trivial to
write and impossible to half-satisfy. The formatter is opinionated by
design — there is no style knob; mixed conventions are rejected outright
instead of negotiated. Pair it with CI (§3.1) and never discuss formatting
again.

### 3.10 `kukicha test` swallowed space-separated unrecognized flag values (Bug — FIXED on v0.86.9, verified)

Observed against v0.86.4 (2026-11-05):

```text
kukicha test . -bench . -benchtime 200x   # → FAIL 200x [setup failed]
```

The unrecognized forwarded flag's space-separated value was not forwarded —
it was silently reinterpreted as a package target, and the run failed as
`FAIL 200x [setup failed]`.

**Verified fixed on v0.86.9** (2026-11-11, this repo, exact 2026-11-05
repro): `kukicha test . -bench . -benchtime 200x` runs all benchmarks at 200
iterations and passes. The `-flag=value` spelling works too but is no longer
called out in this repo's docs (2026-11-11).

## 4. Verified at the command line

Reproduction environment for everything above:

```text
kukicha v0.86.9 (vendored stdlib 0.86.9+e2533b4f; GOAMD64 default v3)
kukicha check ./...            # ✓ pass (and with --strict: ✓ pass)
kukicha fmt --check --json .   # [] after one fix (["phase3_test.kuki"] before)
kukicha test . -count=1        # ok   mizuya   0.133s
```

- `check --strict` clean — advisory lints already promoted on this tree.
- Exit codes probed live against the compiled binary: runtime error →
  `{"error": ...}` exit 1; `cli.UsageFail` / missing required flag → exit 2;
  both JSON and text modes match `docs/output-contract.md`.
- MCP server probed over stdio: 6 tools, zero stray stdout lines, logs on
  stderr only.

## 5. Not problems (so the next review doesn't re-litigate)

- `onerr` auto-propagation fills the trailing `error` — fewer `if err`
  blocks than Go, and the `{error}` name binding is unambiguous once you
  stop writing `{err}`.
- No inheritance: variant enums (tagged unions) with exhaustiveness checks
  replace "switch on type" — the `EntityType` enum and `OKFFrontMatter`
  show the pattern; `Parse<Name>` is generated automatically.
- `reference T` / `optional reference T` make nullability explicit; the
  linter flags `isnt empty` narrowing mistakes (`semantic/nullable-required`).
- Bracket-free syntax is a net readability win for SQL-heavy code — the
  embedded SQL strings carry the eye through without C-style brace noise.
- `.kuki` is the source; generated `*.go` is gitignored — one source of
  truth per commit.

## 6. Verification probes used (2026-11-11)

The "verified / fixed" claims in this file were checked, not transcribed:

- **§3.10 (flag forwarding):** `kukicha test . -bench . -benchtime 200x` in
  this repo — ran all benchmarks at 200 iterations, PASS.
- **§1.3 (sibling test files):** scratch package `/tmp/opencode/kukicha-probe/`
  (`main.kuki` + `a_test.kuki` defining `helperValue()` + `b_test.kuki`
  calling it) — `kukicha check ./...` → ✓.
- **§1.2 (sort copy):** read of vendored `stdlib/sort/sort.go` —
  `Strings`/`Asc`/`By`/`ByKey`/`ByKeyDesc` all `slices.Clone` before sorting.
- **§2.1 (DeepEqual):** scratch test asserting `db.Count(pool, ...)` equals
  `1` — fails with `expected 1, got 1 (same value, different numeric kind —
  want int, got int64)`; vendored `stdlib/test/test.go` uses
  `reflect.DeepEqual` at `AssertEqual`.
- **§2.2 (regex lint):** scratch test calling
  `regex.MustCompile(p)` with a non-literal `p` — `[security/regex-panic]`
  error at `check` time.
- **§2.4 (env errors):** vendored `stdlib/env/env.go` — `Set`/`Unset`
  return `error`.
- Incidentally confirmed healthy on v0.86.9: `check --strict` clean,
  `fmt --check --json` emits an offender list, `kukicha test` re-transpiles
  stale artifacts, exit codes match `docs/output-contract.md`.

Re-run these before trusting any entry here against a new compiler release.

## 7. If you only read one entry

§1.2 and §3.1. The sort-copy footgun is the only item on this list that
produces silently wrong *output* from a well-formed program, and the
absence of a CI gate is the only item that lets it ship. Everything else
is loud, or cheap, or one-time.
